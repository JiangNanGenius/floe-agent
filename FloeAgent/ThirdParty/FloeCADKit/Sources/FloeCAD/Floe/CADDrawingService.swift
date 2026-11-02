//
//  CADDrawingService.swift
//  FloeCADKit
//
//  Drawing-set service for FloeCAD: page management over the persisted
//  `CADDrawingSet` JSON (`Project.drawingsData`), real orthographic projection
//  of document bodies, computed dimensions/centerlines, and vector-only
//  PDF / SVG / R12 DXF export. Nothing in this path rasterizes: every exported
//  byte is vector geometry or text derived from kernel geometry, never a
//  screenshot.
//
//  Contract notes
//  --------------
//  * Projection is real: front/top/side/iso pages run `ProjectionKit`
//    (`projectSilhouette` → "outline", `project` → "edges"); section pages run
//    `OCCTKernel.sectionPolylines` + `SectionKit.loops`; detail pages re-project
//    a standard view and clip it to a model-space window. Near-circular line
//    chains are recognized as circles/arcs (bounded residual + chord-length
//    checks) and, when a matching analytic cylinder face is found on the body's
//    B-rep, the exact kernel radius replaces the tessellation fit — so a Ø10
//    hole dimensions as exactly 10 even though the render mesh is Float32.
//  * Scale is drawing mm per model mm: projected/exported coordinates are
//    model length × `page.scale` (0.5 = half size). Dimension `value`s are the
//    true MODEL lengths (projected span ÷ scale); their leader/extension
//    geometry is in drawing coordinates.
//  * Per-page `modelRevision` records the MAX `Body.meshRevision` over the
//    page's resolvable source bodies, deliberately NOT `document.revision`:
//    `meshRevision` bumps on any in-memory body edit (even before a save), so
//    staleness detects an unsaved edit, while the committed package revision
//    would not. Consequence, by design: a reopened document re-mints
//    `meshRevision` from its load counter, so pages read stale after reopen
//    until they are re-projected once. `pages` reports both the recorded and
//    the live revision; a missing source body is always stale.
//  * `CADDrawingPage` v2 stores the typed detail window (`detailOrigin` /
//    `detailSizeMM`); v3 adds assembly-aware projection (`assemblyMode`,
//    `explodedViewID`), BOM/balloons `showBOM`, `bom`, `balloons`, manual
//    dimensions and text annotations; v4 adds a shared-sheet `sheetViews`
//    list (per-view kind/scale/offset/projection alignment, section/detail
//    windows) and view-scoped, kernel-face-linked dimensions. Every v4 field
//    decodes to a default, so v1/v2/v3 pages load unchanged. Ordinary pages
//    keep projecting raw body transforms; only pages that ask for assembly
//    mode project placed instances (shared bodies and independent copies)
//    with their exploded view offsets. Paper/scale/title remain page data in
//    both modes.
//  * v4 is a drawing-JSON schema floor only; the `.floecad` package format is
//    unchanged and no App version is encoded here. A multi-view page leaves
//    its page-level `sourceBodyIDs` empty and stores the real filter on each
//    view, so an older v3 reader cannot show one bare projection as a
//    complete sheet.
//  * v5 adds structured manufacturing annotations (dimension tolerances with
//    real ISO 286 limits, datum/feature-control frames, surface finish, weld,
//    and thread/counterbore callouts bound to live mechanical holes) plus
//    reusable sheet templates. Those records are non-additive for an older
//    drawing writer, so only documents that really store one raise the
//    package floor (`CADDocumentFormat.drawingManufacturingVersion`). Symbols
//    are vector linework shared by preview, PDF, SVG and DXF; a thread callout
//    is drafting semantics only and never claims geometric helix geometry.
//  * Section honesty (E13): a section view whose sources include a mesh-only
//    body or a missing body/instance is marked `sectionComplete:false` and
//    `outputBlocked:true`; `exportData` refuses it with `incomplete_section`
//    instead of emitting a partial section as a complete drawing. This is
//    not E12 hidden-line classification and does not claim E14 hatching.
//  * Export layers: GEOMETRY (outline/edges/section), DIMENSIONS,
//    CENTERLINES, ANNOTATIONS (manual dimensions/balloons/text), BOM (sheet
//    table) and TITLE (sheet frame + title block + text). DXF is R12 ASCII,
//    `$INSUNITS` = 4 (mm), with a real LAYER table and TEXT entities.
//  * BOM output completeness: `exportData(format:"csv")` is the complete
//    UTF-8 RFC 4180 table (every BOM row and engineering column, exact text).
//    A vector BOM table must fit every row and required engineering column;
//    otherwise PDF/SVG/DXF/PNG refuse `bom_output_incomplete` with actualRows,
//    capacity and nextAction before emitting bytes. The page preview may show
//    a clearly labelled continuation; the CSV remains the full artifact.
//  * Bounds: ≤ 64 pages per set, ≤ 12 source bodies per page. Mutating actions
//    only edit `Project.drawingsData` and return `"mutated": true`; the host
//    commits with `document.save()`. Expected errors are returned as
//    `["ok": false, "error": code, "message": text]`, never thrown, and a
//    corrupt stored blob is refused without being touched.
//

import Foundation
import CoreGraphics
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import simd

@MainActor
public final class CADDrawingService {
    public static let maxPages = 64
    public static let maxSourceBodies = 12

    /// Every action `handle(action:args:)` dispatches. The model-facing
    /// capability arrays and `CadServiceOperationCatalog` are pinned to this
    /// executor vocabulary by `NativeCADCapabilityDiscoveryTests`.
    public nonisolated static let actions: [String] = [
        "standardSheet", "multiViewSheet", "addView", "updateView",
        "removeView", "layoutViews", "dimensionCandidates", "assemblySheet",
        "addPage", "updatePage", "removePage", "setBOM",
        "addBalloon", "updateBalloon", "removeBalloon",
        "addDimension", "updateDimension", "removeDimension",
        "addAnnotation", "updateAnnotation", "removeAnnotation",
        "addManufacturingAnnotation", "updateManufacturingAnnotation",
        "removeManufacturingAnnotation",
        "listTemplates", "createTemplate", "updateTemplate", "copyTemplate",
        "applyTemplate", "deleteTemplate",
        "pages", "project", "dimensions", "export",
    ]

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    // MARK: - Action router

    /// One JSON-shaped action. Expected errors come back as
    /// `["ok": false, "error": code, "message": text]`; mutating actions set
    /// `"mutated": true` so the caller persists with `document.save()`.
    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "drawing", action: action) { return refusal }
        switch action {
        case "pages": return pagesAction()
        case "addPage": return addPageAction(args)
        case "updatePage": return updatePageAction(args)
        case "removePage": return removePageAction(args)
        case "standardSheet": return standardSheetAction(args)
        case "multiViewSheet": return multiViewSheetAction(args)
        case "addView": return addViewAction(args)
        case "updateView": return updateViewAction(args)
        case "removeView": return removeViewAction(args)
        case "layoutViews": return layoutViewsAction(args)
        case "project": return projectAction(args)
        case "dimensions": return dimensionsAction(args)
        case "dimensionCandidates": return dimensionCandidatesAction(args)
        case "export": return exportAction(args)
        case "assemblySheet": return assemblySheetAction(args)
        case "setBOM": return setBOMAction(args)
        case "addBalloon": return addBalloonAction(args)
        case "updateBalloon": return updateBalloonAction(args)
        case "removeBalloon": return removeBalloonAction(args)
        case "addDimension": return addDimensionAction(args)
        case "updateDimension": return updateDimensionAction(args)
        case "removeDimension": return removeDimensionAction(args)
        case "addAnnotation": return addAnnotationAction(args)
        case "updateAnnotation": return updateAnnotationAction(args)
        case "removeAnnotation": return removeAnnotationAction(args)
        case "addManufacturingAnnotation": return addManufacturingAnnotationAction(args)
        case "updateManufacturingAnnotation": return updateManufacturingAnnotationAction(args)
        case "removeManufacturingAnnotation": return removeManufacturingAnnotationAction(args)
        case "listTemplates": return listTemplatesAction()
        case "createTemplate": return createTemplateAction(args)
        case "updateTemplate": return updateTemplateAction(args)
        case "copyTemplate": return copyTemplateAction(args)
        case "applyTemplate": return applyTemplateAction(args)
        case "deleteTemplate": return deleteTemplateAction(args)
        default:
            return fail("unknown_action",
                        "Unknown drawing action '\(action)'. Use "
                            + Self.actions.joined(separator: ", ") + ".")
        }
    }

    // MARK: - Primitive API

    /// Real projected geometry for one page as JSON-safe values (no
    /// screenshot): page record, counts, entities and dimensions.
    public func pageGeometry(pageID: UUID) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let page = set.pages.first(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        let projection = projectPage(page)
        return projectionPayload(page: page, projection: projection, mutated: false)
    }

    /// Real 2D vector export bytes. `format` is "pdf", "svg", "dxf", "png" or
    /// "csv". PDF/SVG/DXF render the same projected vector geometry; PNG is
    /// the one raster format (the same geometry drawn into a white CoreGraphics
    /// bitmap, never a viewport screenshot); CSV is the complete BOM table for
    /// the selected page/view as UTF-8 RFC 4180 rows, with every BOM row and
    /// every engineering column (no vector-table row cap).
    public func exportData(pageID: UUID, format: String) throws -> Data {
        let set: CADDrawingSet
        do {
            set = try CADDrawingSet.decode(from: document.session.document.drawingsData)
        } catch {
            throw CADDocumentError(
                code: "corrupt_drawings",
                message: "The stored drawing set JSON could not be read; it was left untouched.")
        }
        guard let page = set.pages.first(where: { $0.id == pageID }) else {
            throw CADDocumentError(code: "unknown_page", message: "No drawing page with that id.")
        }
        // A page bound to a named exploded view must never silently export the
        // base placement when that view was deleted. The persisted id is the
        // authority; the transient viewport preview is not consulted here.
        if pageMissingExplodedView(page) {
            throw CADDocumentError(
                code: "missing_exploded_view",
                message: "The page's exploded view no longer exists. Select another view "
                    + "or clear the page's exploded view before exporting.")
        }
        let normalizedFormat = format.lowercased()
        guard ["pdf", "svg", "dxf", "png", "csv"].contains(normalizedFormat) else {
            throw CADDocumentError(code: "unknown_format",
                                   message: "format must be pdf, svg, dxf, png or csv.")
        }
        // The BOM table export is data, not projected vector geometry: it does
        // not depend on a section's analytic/mesh completeness. It still uses
        // the SAME page, selected named view and revision as the vector sheet,
        // and a missing named view is refused above for every format.
        if normalizedFormat == "csv" {
            return try bomCSVData(page: page)
        }
        // The vector BOM is all-or-nothing. A page that cannot show every row
        // and every required engineering column refuses vector output instead
        // of drawing a partial table as if it were complete. CSV above remains
        // the usable full-table artifact for exactly this limit.
        if page.showBOM, let bom = page.bom, !bom.entries.isEmpty {
            let layout = bomTableLayout(page: page, rowCount: bom.entries.count)
            if !layout.complete {
                throw bomOutputIncomplete(rowCount: bom.entries.count, layout: layout)
            }
        }
        let projection = projectPage(page)
        if projection.outputBlocked || projection.sectionIncomplete
            || projection.sectionCoverage.contains(where: { !$0.included }) {
            let missingCount = projection.missing.count + projection.missingInstances.count
            let meshOnly = projection.sectionCoverage.filter { !$0.analyticBRep }.count
            let detail = meshOnly > 0
                ? "\(meshOnly) source(s) have no analytic B-rep"
                : "\(max(missingCount, 1)) source(s) are missing"
            throw CADDocumentError(
                code: "incomplete_section",
                message: "This page's section is incomplete: \(detail). Vector output is blocked "
                    + "rather than presenting a partial section as a complete drawing.")
        }
        let graphics = renderGraphics(page: page, projection: projection)
        switch normalizedFormat {
        case "pdf": return try pdfData(page: page, graphics: graphics)
        case "svg": return svgData(page: page, graphics: graphics)
        case "dxf": return dxfData(page: page, graphics: graphics)
        case "png": return try pngData(page: page, graphics: graphics)
        default:
            // The guard above makes this unreachable; keep the compiler's
            // exhaustive switch honest if a future format is added.
            throw CADDocumentError(code: "unknown_format",
                                   message: "format must be pdf, svg, dxf, png or csv.")
        }
    }

    // MARK: - Read actions

    private func pagesAction() -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        let assembly = loadAssemblyValue()
        var rows: [[String: Any]] = []
        rows.reserveCapacity(set.pages.count)
        for page in set.pages {
            var row = pagePayload(page)
            let live = liveFingerprint(for: page)
            let missing = live.sources.filter(\.missing).map(\.bodyID)
            row["stale"] = page.isStale(against: live)
            row["outputMatches"] = !page.isStale(against: live)
            row["viewCount"] = page.effectiveSheetViews.count
            row["isMultiView"] = page.isMultiViewSheet
            row["sectionIncomplete"] = pageSectionIncomplete(page)
            row["missingExplodedView"] = pageMissingExplodedView(page)
            row["outputBlocked"] = pageSectionIncomplete(page) || pageMissingExplodedView(page)
            row["vectorOutputBlocked"] = row["outputBlocked"] as? Bool ?? false
            if let revision = maxMeshRevision(for: page) { row["liveRevision"] = revision }
            if !missing.isEmpty {
                row["missingBodyIDs"] = missing.map(\.uuidString)
            }
            let binding = pageBindingReport(page: page, assembly: assembly)
            row["bindingIssueCount"] = binding.issueCount
            row["bindingIssues"] = binding.messages
            if !binding.missingInstanceIDs.isEmpty {
                row["missingInstanceIDs"] = binding.missingInstanceIDs
            }
            if page.showBOM { row["bomCount"] = page.bom?.entries.count ?? 0 }
            if let bom = page.bom, !bom.entries.isEmpty {
                let output = bomOutputStatus(page: page, rowCount: bom.entries.count)
                row["bomOutput"] = output
                row["bomTotalRows"] = bom.entries.count
                row["bomVectorComplete"] = output["vectorComplete"] ?? false
                row["bomVectorCapacity"] = output["capacity"] ?? 0
                row["vectorOutputBlocked"] = (row["vectorOutputBlocked"] as? Bool ?? false)
                    || !(output["vectorComplete"] as? Bool ?? false)
            }
            rows.append(row)
        }
        return ["ok": true, "count": rows.count, "maxPages": Self.maxPages, "pages": rows]
    }

    private func dimensionsAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let page = set.pages.first(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        let projection = projectPage(page)
        let dims = dimensions(for: page, projection: projection)
        let manual = resolvedManualDimensions(page: page, projection: projection)
        return ["ok": true,
                "pageID": id.uuidString,
                "count": dims.count,
                "dimensions": dims.map(dimensionPayload),
                "manualDimensions": manual.rows,
                "manualDimensionCount": manual.rows.count,
                "dimensionBindingIssues": manual.issues]
    }

    /// Read-only candidates for a linked dimension: cylindrical kernel faces
    /// whose axis is parallel to the view. Each row carries the exact
    /// `reference` object `addDimension.feature` accepts. Visibility is NOT
    /// classified (that is E12 hidden-line scope); the note says so.
    private func dimensionCandidatesAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let page = set.pages.first(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        let requestedViewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"])
        let views = page.effectiveSheetViews.filter { item in
            requestedViewID.map { id in id == item.id } ?? true
        }
        guard !views.isEmpty else {
            return fail("unknown_view", "viewID does not reference a view on this page.")
        }
        let projection = projectPage(page)
        let assembly = loadAssemblyValue()
        var candidates: [[String: Any]] = []
        var notes: [String] = []
        for view in views {
            guard let plane = plane(for: page, view: view) else { continue }
            let projectionOffset = projection.views.first {
                $0.view.id == view.id
            }?.offset ?? .zero
            let resolved = projectionSources(for: page, sourceBodyIDs: view.sourceBodyIDs)
            var viewHasAmbiguousAuthorship = false
            for source in resolved.sources {
                guard let brep = source.body.brep else { continue }
                let sourceBodyID: UUID
                if let instanceID = source.instanceID,
                   let instance = assembly?.instance(instanceID) {
                    sourceBodyID = effectiveBodyID(instance)
                } else {
                    sourceBodyID = source.body.id.raw
                }
                for face in OCCTKernel.faceInfo(brep) {
                    guard let signature = face.signature,
                          case let .cylindrical(radius) = signature.kind else { continue }
                    let worldAxis = simd_normalize(
                        source.body.transform.rotation.act(signature.normal))
                    guard abs(simd_dot(worldAxis, plane.normal)) >= 0.995 else { continue }
                    let worldCentroid = source.body.transform.applying(to: signature.centroid)
                    let local = plane.toLocal(worldCentroid) * view.scale
                    let sheet = local + projectionOffset
                    var reference: [String: Any] = [
                        "kind": "cylindricalFace",
                        "bodyID": sourceBodyID.uuidString,
                        "instanceID": (source.instanceID?.uuidString as Any?) ?? (NSNull() as Any),
                        "anchor": [
                            "centroid": vectorPayload(signature.centroid),
                            "direction": vectorPayload(signature.normal),
                            "radiusMM": radius,
                            "toleranceMM": 0.5,
                        ],
                        "sourceRevision": source.body.meshRevision,
                    ]
                    switch featureProvenance(
                        bodyID: sourceBodyID, radius: radius,
                        centroid: signature.centroid, normal: signature.normal,
                        world: body(for: sourceBodyID)?.transform ?? source.body.transform) {
                    case .unique(let featureID, let sketchID, let entityID):
                        reference["featureID"] = featureID.uuidString
                        reference["sketchID"] = sketchID.uuidString
                        reference["sketchEntityID"] = entityID.uuidString
                    case .ambiguous:
                        // Structured ambiguity: name no author and say why.
                        // The caller must re-select an explicit
                        // featureID/sketchID/sketchEntityID, which
                        // resolveFeatureFace then validates against the live
                        // model — never adopt the newest/first similar one.
                        reference["provenanceAmbiguity"] = true
                        viewHasAmbiguousAuthorship = true
                    case .none:
                        // An unresolved author may also be an unsupported
                        // native feature, so do not label it as imported.
                        reference["provenanceState"] = "geometryOnly"
                    }
                    var row: [String: Any] = [
                        "viewID": view.id.uuidString,
                        "viewName": view.name,
                        "kind": view.kind.rawValue,
                        "bodyID": sourceBodyID.uuidString,
                        "bodyName": source.name,
                        "faceIndex": face.index,
                        "radiusMM": radius,
                        "center": pointPayload(local),
                        "sheetCenter": pointPayload(sheet),
                        "radiusInView": radius * view.scale,
                        "reference": reference,
                    ]
                    if let instanceID = source.instanceID {
                        row["instanceID"] = instanceID.uuidString
                    }
                    candidates.append(row)
                }
            }
            if page.sheetViews != nil {
                notes.append("View \(view.name): cylindrical faces parallel to the view; "
                             + "hidden-line visibility is not classified (E12).")
            }
            if viewHasAmbiguousAuthorship {
                notes.append("View \(view.name): a cylindrical face here is authored by more "
                             + "than one feature; the candidates name no single author. "
                             + "Re-select an explicit featureID/sketchID/sketchEntityID — "
                             + "it is validated against the model before it is used.")
            }
        }
        return ["ok": true, "pageID": pageID.uuidString,
                "viewID": (requestedViewID?.uuidString as Any?) ?? NSNull(),
                "count": candidates.count,
                "candidates": candidates,
                "notes": notes]
    }

    /// Whether `node` writes (produces, boolean-targets, or tools) `target`.
    /// Shared by provenance capture and the linked-dimension identity gate.
    private static func featureNode(_ node: FeatureNode, writesBody target: BodyID) -> Bool {
        if node.outputBodyIDs.contains(target) { return true }
        switch node.kind {
        case let .extrude(_, _, _, _, boolean, _, _),
             let .draftExtrude(_, _, _, _, _, boolean):
            return boolean.resolvedTargets.contains { $0.bodyID == target }
        case let .revolve(_, _, _, _, boolean):
            return boolean.resolvedTargets.contains { $0.bodyID == target }
        case let .sweep(_, _, _, boolean, _, _):
            return boolean.resolvedTargets.contains { $0.bodyID == target }
        case let .loft(_, boolean):
            return boolean.resolvedTargets.contains { $0.bodyID == target }
        case let .boolean(_, body, tools):
            return body.bodyID == target || tools.contains { $0.bodyID == target }
        case let .hole(body, _, _, _):
            return body.bodyID == target
        default:
            return false
        }
    }

    /// Provenance capture outcome for one cylindrical kernel face.
    private enum ProvenanceCapture {
        /// Exactly one (feature, sketch, circle entity) triple authored the
        /// face; safe to capture as the linked dimension's identity.
        case unique(featureID: UUID, sketchID: UUID, entityID: UUID)
        /// Several distinct triples match the face; authorship is genuinely
        /// ambiguous and must be reported so the caller re-selects an
        /// explicit source instead of adopting the newest/first similar one.
        case ambiguous
        /// No eligible circle author was resolved. This includes imported,
        /// legacy and unsupported authoring paths; no identity is invented.
        case none
    }

    /// Provenance only: find the feature/sketch circle that authored a
    /// cylindrical face. EVERY eligible writer of the body is scanned — not
    /// just the newest one — because holes are usually boolean-cut into the
    /// SAME body: a dimension linked to an earlier hole must still capture
    /// that hole even after later unrelated features exist. A match requires
    /// the authoring circle's radius and radial position to agree with the
    /// live kernel face; exactly one matching triple is the author, several
    /// is structured ambiguity (never resolved by picking the newest or
    /// first similar circle), none keeps only the geometric anchor. The
    /// linked dimension's AUTHORITY remains the live face anchor; this
    /// triple lets the UI/Agent show and diagnose the originating feature
    /// after a rebuild. Suppressed features cannot author live geometry, so
    /// they are skipped.
    private func featureProvenance(bodyID: UUID,
                                   radius: Double,
                                   centroid: SIMD3<Double>,
                                   normal: SIMD3<Double>,
                                   world: Transform3D)
        -> ProvenanceCapture {
        let worldAxis = simd_normalize(world.rotation.act(normal))
        let worldCentroid = world.applying(to: centroid)
        let radiusLimit = max(0.25, radius * 0.05)
        let target = BodyID(raw: bodyID)
        var match: (featureID: UUID, sketchID: UUID, entityID: UUID)?
        for node in document.session.document.features.nodes
        where !node.suppressed
            && Self.featureNode(node, writesBody: target)
            && !node.referencedSketchIDs.isEmpty {
            for sketchID in node.referencedSketchIDs {
                guard let sketch = document.session.document.sketches.first(where: { $0.id == sketchID }) else {
                    continue
                }
                for entity in sketch.entities {
                    guard case let .circle(entityID, center, entityRadius) = entity,
                          abs(entityRadius - radius) <= radiusLimit else { continue }
                    let sketchCenter = sketch.plane.toWorld(center)
                    let delta = sketchCenter - worldCentroid
                    let radial = delta - simd_dot(delta, worldAxis) * worldAxis
                    guard simd_length(radial) <= max(1.0, radius * 0.75) else { continue }
                    let candidate = (featureID: node.id.raw,
                                     sketchID: sketchID.raw,
                                     entityID: entityID)
                    guard let existing = match else {
                        match = candidate
                        continue
                    }
                    // The same triple surfacing twice is one author; a
                    // DIFFERENT triple (another feature, sketch or circle)
                    // is real ambiguity, not a tie-break by recency.
                    if existing.featureID != candidate.featureID
                        || existing.sketchID != candidate.sketchID
                        || existing.entityID != candidate.entityID {
                        return .ambiguous
                    }
                }
            }
        }
        guard let match else { return .none }
        return .unique(featureID: match.featureID,
                       sketchID: match.sketchID,
                       entityID: match.entityID)
    }

    private func projectAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var updated = set
        var page = updated.pages[index]
        let projection = projectPage(page)
        // Pin the identity the geometry was generated from: the ordered
        // per-source content/placement fingerprint (authoritative) plus the
        // informational max meshRevision.
        var mutated = false
        let live = liveFingerprint(for: page)
        let hasGeometry = !page.effectiveSourceBodyIDs.isEmpty
            || !(live.instances ?? []).isEmpty
        if live.sources.allSatisfy({ !$0.missing }), hasGeometry {
            let revision = maxMeshRevision(for: page)
            if page.sourceFingerprint != live || page.modelRevision != revision {
                page.sourceFingerprint = live
                page.modelRevision = revision
                updated.pages[index] = page
                if !document.isReadOnly, !document.session.isSketchPreviewActive {
                    if let failure = persist(updated, projectionCacheOnly: true) { return failure }
                    mutated = true
                }
            }
        }
        return projectionPayload(page: page, projection: projection, mutated: mutated)
    }

    // MARK: - Mutating actions

    private func addPageAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        var updated = set
        guard updated.pages.count < Self.maxPages else {
            return fail("too_many_pages", "A drawing set is bounded to \(Self.maxPages) pages.")
        }
        switch buildPage(args: args, existing: nil) {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let page):
            updated.pages.append(page)
            if let failure = persist(updated) { return failure }
            return ["ok": true,
                    "mutated": true,
                    "page": pagePayload(page),
                    "pageCount": updated.pages.count]
        }
    }

    private func updatePageAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        var updated = set
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = updated.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        if updated.pages[index].isMultiViewSheet {
            let viewFields: Set<String> = [
                "kind", "bodyIDs", "sourceBodyIDs", "scale", "viewNormal", "viewUp",
                "sectionOrigin", "sectionNormal", "detailOrigin", "detailSizeMM",
                "assemblyMode", "explodedViewID", "explodedViewName",
            ]
            if viewFields.contains(where: { args.keys.contains($0) }) {
                return fail("multi_view_page",
                            "This is a shared-sheet page; edit its views with addView/updateView "
                            + "and its annotations with viewID, not with page-level view fields.")
            }
        }
        switch buildPage(args: args, existing: updated.pages[index]) {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let page):
            updated.pages[index] = page
            if let failure = persist(updated) { return failure }
            return ["ok": true,
                    "mutated": true,
                    "page": pagePayload(page),
                    "pageCount": updated.pages.count]
        }
    }

    private func removePageAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        var updated = set
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard updated.pages.contains(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        updated.pages.removeAll { $0.id == id }
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "removedPageID": id.uuidString, "pageCount": updated.pages.count]
    }

    private func standardSheetAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        var updated = set
        let rawBody = args["bodyID"] ?? (args["bodyIDs"] as? [String])?.first
        guard let bodyID = uuidValue(rawBody), body(for: bodyID) != nil else {
            return fail("unknown_body", "bodyID must reference a live document body.")
        }
        let title = (args["title"] as? String) ?? document.name
        let sheet = CADDrawingSet.standardSheet(for: bodyID, title: title)
        let replace = boolValue(args["replace"]) ?? false
        var pages = replace ? [] : updated.pages
        pages.append(contentsOf: sheet.pages)
        guard pages.count <= Self.maxPages else {
            return fail("too_many_pages", "A drawing set is bounded to \(Self.maxPages) pages.")
        }
        updated.pages = pages
        if let failure = persist(updated) { return failure }
        return [
            "ok": true,
            "mutated": true,
            "pageCount": updated.pages.count,
            "createdIDs": sheet.pages.map(\.id.uuidString),
            "pages": sheet.pages.map(pagePayload),
        ]
    }

    // MARK: - Reusable sheet templates (schema v5)

    private func listTemplatesAction() -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        let builtIns = CADDrawingSheetTemplateLibrary.builtIns.compactMap {
            templatePayload($0)
        }
        let saved = set.templates.compactMap { templatePayload($0) }
        return ["ok": true, "mutated": false,
                "builtIns": builtIns, "templates": saved,
                "builtInCount": builtIns.count, "count": saved.count]
    }

    private func createTemplateAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard set.templates.count < 64 else {
            return fail("too_many_templates", "A document is bounded to 64 saved templates.")
        }
        let template: CADDrawingSheetTemplate
        switch parseTemplate(args, starting: nil) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): template = parsed
        }
        if CADDrawingSheetTemplateLibrary.isBuiltIn(id: template.id)
            || set.templates.contains(where: { $0.id == template.id }) {
            return fail("duplicate_template", "That template id is already in use.")
        }
        var updated = set
        updated.templates.append(template)
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "template": templatePayload(template) ?? [:],
                "templates": updated.templates.compactMap { templatePayload($0) },
                "count": updated.templates.count]
    }

    private func updateTemplateAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let templateID = uuidValue(args["templateID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_template_id", "templateID must be a template UUID string.")
        }
        if CADDrawingSheetTemplateLibrary.isBuiltIn(id: templateID) {
            return fail("built_in_template",
                        "Built-in presets are read-only; copy one to edit it.")
        }
        guard let index = set.templates.firstIndex(where: { $0.id == templateID }) else {
            return fail("unknown_template", "No saved template with that id.")
        }
        let template: CADDrawingSheetTemplate
        switch parseTemplate(args, starting: set.templates[index]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): template = parsed
        }
        var updated = set
        updated.templates[index] = template
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "template": templatePayload(template) ?? [:],
                "templates": updated.templates.compactMap { templatePayload($0) },
                "count": updated.templates.count]
    }

    private func copyTemplateAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard set.templates.count < 64 else {
            return fail("too_many_templates", "A document is bounded to 64 saved templates.")
        }
        guard let sourceID = uuidValue(args["templateID"]) ?? uuidValue(args["sourceTemplateID"]) else {
            return fail("bad_template_id", "templateID must be a template UUID string.")
        }
        let source = CADDrawingSheetTemplateLibrary.preset(id: sourceID)
            ?? set.templates.first { $0.id == sourceID }
        guard let source else {
            return fail("unknown_template", "No built-in or saved template with that id.")
        }
        var copy = source
        copy.id = UUID()
        copy.builtIn = false
        if let name = args["name"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.name = name
        } else {
            copy.name = source.name + " Copy"
        }
        let issues = CADDrawingTemplateRules.validate(copy)
        guard issues.isEmpty else {
            return fail("invalid_template", issues.joined(separator: " "))
        }
        var updated = set
        updated.templates.append(copy)
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "template": templatePayload(copy) ?? [:],
                "templates": updated.templates.compactMap { templatePayload($0) },
                "count": updated.templates.count]
    }

    private func deleteTemplateAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let templateID = uuidValue(args["templateID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_template_id", "templateID must be a template UUID string.")
        }
        if CADDrawingSheetTemplateLibrary.isBuiltIn(id: templateID) {
            return fail("built_in_template", "Built-in presets cannot be deleted.")
        }
        guard set.templates.contains(where: { $0.id == templateID }) else {
            return fail("unknown_template", "No saved template with that id.")
        }
        var updated = set
        updated.templates.removeAll { $0.id == templateID }
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "removedTemplateID": templateID.uuidString,
                "templates": updated.templates.compactMap { templatePayload($0) },
                "count": updated.templates.count,
                "appliedPageSnapshotsPreserved": true]
    }

    /// Apply ONE template to several pages as a single drawing-set command
    /// (one undo step). Every page keeps its id, views, source binding and
    /// annotations; only sheet presentation/display settings change. All page
    /// ids are validated before any byte is persisted, so a bad request rolls
    /// back the whole batch.
    private func applyTemplateAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let templateID = uuidValue(args["templateID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_template_id", "templateID must be a template UUID string.")
        }
        guard let template = CADDrawingSheetTemplateLibrary.preset(id: templateID)
                ?? set.templates.first(where: { $0.id == templateID }) else {
            return fail("unknown_template", "No built-in or saved template with that id.")
        }
        let issues = CADDrawingTemplateRules.validate(template)
        guard issues.isEmpty else {
            return fail("invalid_template", issues.joined(separator: " "))
        }
        let rawIDs: [String]
        if let list = args["pageIDs"] as? [String] {
            rawIDs = list
        } else if let one = args["pageID"] as? String {
            rawIDs = [one]
        } else {
            return fail("bad_page_ids", "pageIDs must be a non-empty array of page UUID strings.")
        }
        guard !rawIDs.isEmpty, rawIDs.count <= Self.maxPages else {
            return fail("bad_page_ids", "pageIDs must name 1…\(Self.maxPages) pages.")
        }
        var ids: [UUID] = []
        for raw in rawIDs {
            guard let id = UUID(uuidString: raw) else {
                return fail("bad_page_ids", "pageIDs must all be page UUID strings.")
            }
            ids.append(id)
        }
        guard Set(ids).count == ids.count else {
            return fail("duplicate_page", "pageIDs must not repeat.")
        }
        var indexes: [Int] = []
        for id in ids {
            guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
                return fail("unknown_page", "pageIDs must all reference pages in this set.")
            }
            indexes.append(index)
        }
        var updated = set
        for index in indexes {
            do {
                try CADDrawingTemplateRules.apply(template, to: &updated.pages[index])
            } catch {
                return fail("template_apply_failed", error.localizedDescription)
            }
        }
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "transaction": "single",
                "undoSteps": 1,
                "appliedPageIDs": ids.map(\.uuidString),
                "appliedCount": ids.count,
                "template": templatePayload(template) ?? [:],
                "pages": indexes.map { pagePayload(updated.pages[$0]) }]
    }

    private func parseTemplate(_ args: [String: Any],
                               starting: CADDrawingSheetTemplate?)
        -> Result<CADDrawingSheetTemplate, CADDrawingServiceError> {
        var template = starting ?? CADDrawingSheetTemplate(
            id: uuidValue(args["id"]) ?? UUID(), name: "New template")
        template.builtIn = false
        if let raw = args["name"] {
            guard let name = raw as? String else {
                return .failure(CADDrawingServiceError(
                    code: "bad_template_name", message: "name must be a string."))
            }
            template.name = name
        }
        if let raw = args["paper"] {
            guard let name = raw as? String, let paper = CADPaperSize(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_paper",
                    message: "paper must be a4, a3, a2, a1, a0, letter, tabloid or custom."))
            }
            template.paper = paper
        }
        if let raw = args["customWidthMM"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_paper_size", message: "customWidthMM must be positive and finite."))
            }
            template.customWidthMM = value
        }
        if let raw = args["customHeightMM"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_paper_size", message: "customHeightMM must be positive and finite."))
            }
            template.customHeightMM = value
        }
        if let raw = args["projection"] {
            guard let name = raw as? String,
                  let projection = CADDrawingProjectionMethod(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_projection", message: "projection must be firstAngle or thirdAngle."))
            }
            template.projection = projection
        }
        if let raw = args["units"] {
            guard let name = raw as? String, let unit = CADDrawingUnit(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_unit", message: "units must be millimetre, centimetre or inch."))
            }
            template.units = unit
        }
        if let raw = args["precision"] {
            guard let value = intValue(raw), (0...4).contains(value) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_precision", message: "precision must be an integer from 0 to 4."))
            }
            template.precision = value
        }
        if let raw = args["style"], !(raw is NSNull) {
            guard let object = raw as? [String: Any] else {
                return .failure(CADDrawingServiceError(
                    code: "bad_template_style", message: "style must be an object."))
            }
            let allowed = Set(["marginMM", "titleBlockWidthMM", "titleBlockHeightMM",
                               "lineWidthMM", "textHeightMM", "showZoneGrid"])
            let unknown = Set(object.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_template_field",
                    message: "Unknown style field(s): \(unknown.sorted().joined(separator: ", "))."))
            }
            if let value = doubleValue(object["marginMM"]) { template.style.marginMM = value }
            if let value = doubleValue(object["titleBlockWidthMM"]) {
                template.style.titleBlockWidthMM = value
            }
            if let value = doubleValue(object["titleBlockHeightMM"]) {
                template.style.titleBlockHeightMM = value
            }
            if let value = doubleValue(object["lineWidthMM"]) { template.style.lineWidthMM = value }
            if let value = doubleValue(object["textHeightMM"]) { template.style.textHeightMM = value }
            if let value = boolValue(object["showZoneGrid"]) { template.style.showZoneGrid = value }
        }
        if let raw = args["titleBlock"], !(raw is NSNull) {
            guard let object = raw as? [String: Any] else {
                return .failure(CADDrawingServiceError(
                    code: "bad_title_block", message: "titleBlock must be an object."))
            }
            let unknown = Set(object.keys).subtracting(["company", "drawingNumber"])
            guard unknown.isEmpty else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_template_field",
                    message: "Unknown titleBlock field(s): \(unknown.sorted().joined(separator: ", "))."))
            }
            if let company = object["company"] as? String { template.titleBlock.company = company }
            if let number = object["drawingNumber"] as? String {
                template.titleBlock.drawingNumber = number
            }
        }
        if let raw = args["revisionRows"] {
            if raw is NSNull {
                template.revisionRows = []
            } else {
                guard let rows = raw as? [[String: Any]] else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_revision_rows",
                        message: "revisionRows must be an array of row objects."))
                }
                guard rows.count <= CADDrawingTemplateRules.maximumRevisionRows else {
                    return .failure(CADDrawingServiceError(
                        code: "too_many_revision_rows",
                        message: "A template supports at most \(CADDrawingTemplateRules.maximumRevisionRows) revision rows."))
                }
                var parsed: [CADDrawingRevisionRow] = []
                for row in rows {
                    let unknown = Set(row.keys).subtracting(["id", "revision", "date",
                                                             "description", "approvedBy"])
                    guard unknown.isEmpty else {
                        return .failure(CADDrawingServiceError(
                            code: "unknown_template_field",
                            message: "Unknown revision row field."))
                    }
                    guard let revision = row["revision"] as? String,
                          let description = row["description"] as? String else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_revision_rows",
                            message: "Each revision row needs revision and description strings."))
                    }
                    guard row["date"] == nil || row["date"] is String || row["date"] is NSNull,
                          row["approvedBy"] == nil || row["approvedBy"] is String
                            || row["approvedBy"] is NSNull else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_revision_rows",
                            message: "date/approvedBy must be strings or null."))
                    }
                    let date = row["date"] as? String ?? ""
                    let approvedBy = row["approvedBy"] as? String
                    guard revision.count <= 16, date.count <= 24,
                          description.count <= 80, (approvedBy?.count ?? 0) <= 40 else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_revision_rows",
                            message: "A revision row field is longer than its bound."))
                    }
                    parsed.append(CADDrawingRevisionRow(
                        id: uuidValue(row["id"]) ?? UUID(), revision: revision,
                        date: row["date"] as? String ?? "", description: description,
                        approvedBy: row["approvedBy"] as? String))
                }
                template.revisionRows = parsed
            }
        }
        let issues = CADDrawingTemplateRules.validate(template)
        guard issues.isEmpty else {
            return .failure(CADDrawingServiceError(
                code: "invalid_template", message: issues.joined(separator: " ")))
        }
        return .success(template)
    }

    private func templatePayload(_ template: CADDrawingSheetTemplate) -> [String: Any]? {
        guard let object = jsonObject(template) as? [String: Any] else { return nil }
        var payload = object
        payload["builtIn"] = template.builtIn
        return payload
    }

    // MARK: - Shared-sheet multi-view

    /// Create ONE page carrying front/top/side/section views. The views share
    /// the page paper and title block; each owns its scale/placement and a
    /// projection-alignment reference. Page-level `sourceBodyIDs` stays empty
    /// (a v3 reader then cannot show a bare front view as the whole sheet).
    private func multiViewSheetAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        var updated = set
        guard updated.pages.count < Self.maxPages else {
            return fail("too_many_pages", "A drawing set is bounded to \(Self.maxPages) pages.")
        }
        var bodyIDs: [UUID] = []
        if let raw = args["bodyIDs"] ?? args["sourceBodyIDs"] ?? args["bodyID"] {
            let strings: [String]
            if let one = raw as? String { strings = [one] }
            else if let list = raw as? [String] { strings = list }
            else { return fail("bad_body_ids", "bodyIDs must be an array of body UUID strings.") }
            for string in strings {
                guard let id = UUID(uuidString: string) else {
                    return fail("bad_body_ids", "bodyIDs must be body UUID strings.")
                }
                guard body(for: id) != nil else {
                    return fail("unknown_body", "bodyIDs must all reference live document bodies.")
                }
                bodyIDs.append(id)
            }
            guard bodyIDs.count <= Self.maxSourceBodies else {
                return fail("too_many_bodies",
                            "A page is bounded to \(Self.maxSourceBodies) source bodies.")
            }
            guard Set(bodyIDs).count == bodyIDs.count else {
                return fail("duplicate_body", "bodyIDs must not repeat.")
            }
        }
        var assemblyMode = boolValue(args["assemblyMode"]) ?? false
        var explodedViewID: UUID?
        if let raw = args["explodedViewID"], !(raw is NSNull) {
            guard let id = uuidValue(raw),
                  let assembly = loadAssemblyValue(),
                  assembly.explodedView(id) != nil else {
                return fail("unknown_exploded_view",
                            "explodedViewID does not reference a stored exploded view.")
            }
            explodedViewID = id
            assemblyMode = true
        }
        if assemblyMode && bodyIDs.isEmpty {
            guard let assembly = loadAssemblyValue(),
                  assembly.occurrences(includeHidden: false).contains(where: { $0.isDrawablePart }) else {
                return fail("empty_assembly",
                            "Place assembly instances before creating an assembly drawing sheet.")
            }
        }
        guard assemblyMode || !bodyIDs.isEmpty else {
            return fail("missing_body",
                        "multiViewSheet needs bodyIDs (or assemblyMode with placed instances).")
        }
        var scale = 1.0
        if let raw = args["scale"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0, value <= 1000 else {
                return fail("bad_scale", "scale must be a finite number in (0, 1000].")
            }
            scale = value
        }
        var paper = CADPaperSize.a3
        if let raw = args["paper"] {
            guard let name = raw as? String, let parsed = CADPaperSize(rawValue: name) else {
                return fail("unknown_paper",
                            "paper must be a4, a3, a2, a1, a0, letter, tabloid or custom.")
            }
            paper = parsed
        }
        let sectionNormal: SIMD3<Double>
        if let raw = args["sectionNormal"] {
            guard let vector = vector3(raw), simd_length(vector) > 1e-9 else {
                return fail("bad_section_normal", "sectionNormal must be a non-zero finite [x,y,z].")
            }
            sectionNormal = simd_normalize(vector)
        } else if let derived = derivedSectionNormal(bodyIDs: bodyIDs,
                                                     assemblyMode: assemblyMode,
                                                     explodedViewID: explodedViewID) {
            sectionNormal = derived
        } else {
            return fail("missing_section_plane",
                        "Could not derive a section normal from the selected sources; "
                        + "pass sectionNormal and sectionOrigin.")
        }
        let sectionOrigin: SIMD3<Double>
        if let raw = args["sectionOrigin"] {
            guard let vector = vector3(raw) else {
                return fail("bad_section_origin", "sectionOrigin must be a finite [x,y,z].")
            }
            sectionOrigin = vector
        } else {
            guard let origin = derivedSectionOrigin(bodyIDs: bodyIDs,
                                                    assemblyMode: assemblyMode,
                                                    explodedViewID: explodedViewID) else {
                return fail("missing_section_plane",
                            "Could not derive a section plane from the selected sources; "
                            + "pass sectionOrigin and sectionNormal.")
            }
            sectionOrigin = origin
        }
        let title = (args["title"] as? String) ?? document.name
        let viewName = explodedViewID.flatMap { loadAssemblyValue()?.explodedView($0)?.name }
        let sheet = CADDrawingSet.multiViewSheet(
            bodyIDs: bodyIDs, title: title, scale: scale, paper: paper,
            sectionOrigin: sectionOrigin, sectionNormal: sectionNormal,
            assemblyMode: assemblyMode, explodedViewID: explodedViewID,
            explodedViewName: viewName)
        let replace = boolValue(args["replace"]) ?? false
        var pages = replace ? [] : updated.pages
        pages.append(contentsOf: sheet.pages)
        guard pages.count <= Self.maxPages else {
            return fail("too_many_pages", "A drawing set is bounded to \(Self.maxPages) pages.")
        }
        updated.pages = pages
        // Place the free front view against the real projected bounds so the
        // sheet is usable immediately; the aligned views derive from it.
        if let pageIndex = updated.pages.firstIndex(where: { $0.id == sheet.pages[0].id }) {
            var page = updated.pages[pageIndex]
            if let frontIndex = page.effectiveSheetViews.firstIndex(where: {
                $0.alignment.placement == .free
            }) {
                let preview = projectSheetPreview(page)
                let frontID = page.effectiveSheetViews[frontIndex].id
                if let bounds = preview.views.first(where: { $0.view.id == frontID })?.localBounds,
                   var views = page.sheetViews, frontIndex < views.count {
                    views[frontIndex].offset = SIMD2(30 - bounds.min.x, 150 - bounds.min.y)
                    page.sheetViews = views
                }
            }
            updated.pages[pageIndex] = page
        }
        if let failure = persist(updated) { return failure }
        guard let created = updated.pages.last else {
            return fail("page_failed", "The multi-view sheet page could not be created.")
        }
        return ["ok": true, "mutated": true,
                "pageCount": updated.pages.count,
                "page": pagePayload(created),
                "createdViewIDs": created.effectiveSheetViews.map(\.id.uuidString),
                "createdIDs": [created.id.uuidString]]
    }

    /// Derive a mid-model section origin from the current sources. The plane
    /// is centred on the combined world bounds, which keeps a new section
    /// inside the solid for ordinary parts. Callers can override both fields.
    private func sectionSourceBodies(bodyIDs: [UUID],
                                     assemblyMode: Bool,
                                     explodedViewID: UUID?) -> [Body] {
        if assemblyMode, let assembly = loadAssemblyValue() {
            let occurrences = assembly.occurrences(viewID: explodedViewID, includeHidden: false)
                .filter { $0.isDrawablePart }
            var bodies: [Body] = []
            for occurrence in occurrences {
                guard let sourceID = occurrence.effectiveBodyID,
                      let source = body(for: sourceID) else { continue }
                let placement = occurrence.explodedWorldTransform ?? occurrence.worldTransform
                guard placement.isPlaceable else { continue }
                var placed = source
                placed.transform = placement.placement3D().composed(onto: source.transform)
                bodies.append(placed)
            }
            return bodies
        }
        return bodyIDs.compactMap { body(for: $0) }
    }

    private func derivedSectionOrigin(bodyIDs: [UUID],
                                      assemblyMode: Bool,
                                      explodedViewID: UUID?) -> SIMD3<Double>? {
        let bodies = sectionSourceBodies(bodyIDs: bodyIDs,
                                         assemblyMode: assemblyMode,
                                         explodedViewID: explodedViewID)
        guard let bounds = MeasureKit.boundingBox(bodies: bodies) else { return nil }
        return (bounds.min + bounds.max) / 2
    }

    /// Default a new sheet's section normal along the smallest world extent:
    /// for a plate that cuts through the thickness and shows the largest face
    /// (and its bores). Callers can always override sectionNormal explicitly.
    private func derivedSectionNormal(bodyIDs: [UUID],
                                      assemblyMode: Bool,
                                      explodedViewID: UUID?) -> SIMD3<Double>? {
        let bodies = sectionSourceBodies(bodyIDs: bodyIDs,
                                         assemblyMode: assemblyMode,
                                         explodedViewID: explodedViewID)
        guard let bounds = MeasureKit.boundingBox(bodies: bodies) else { return nil }
        let extents = bounds.max - bounds.min
        if extents.y <= extents.x && extents.y <= extents.z { return SIMD3(0, 1, 0) }
        if extents.z <= extents.x && extents.z <= extents.y { return SIMD3(0, 0, 1) }
        return SIMD3(1, 0, 0)
    }

    private func addViewAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let pageIndex = set.pages.firstIndex(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var updated = set
        var page = updated.pages[pageIndex]
        var views = page.effectiveSheetViews
        guard views.count < 16 else {
            return fail("too_many_views", "A sheet is bounded to 16 views.")
        }
        switch buildSheetView(args: args, existing: nil, page: page, views: views) {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let view):
            views.append(view)
            if page.sheetViews == nil { page.sourceBodyIDs = [] }
            if view.kind == .exploded { page.assemblyMode = true }
            page.sheetViews = views
            updated.pages[pageIndex] = page
            if let failure = persist(updated) { return failure }
            return ["ok": true, "mutated": true,
                    "page": pagePayload(page),
                    "view": viewPayload(view)]
        }
    }

    private func updateViewAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let pageIndex = set.pages.firstIndex(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var updated = set
        var page = updated.pages[pageIndex]
        var views = page.effectiveSheetViews
        guard let viewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"]),
              let viewIndex = views.firstIndex(where: { $0.id == viewID }) else {
            return fail("unknown_view", "No sheet view with that id on this page.")
        }
        switch buildSheetView(args: args, existing: views[viewIndex],
                              page: page, views: views) {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let view):
            views[viewIndex] = view
            if view.kind == .exploded { page.assemblyMode = true }
            page.sheetViews = views
            updated.pages[pageIndex] = page
            if let failure = persist(updated) { return failure }
            return ["ok": true, "mutated": true,
                    "page": pagePayload(page),
                    "view": viewPayload(view)]
        }
    }

    private func removeViewAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let pageIndex = set.pages.firstIndex(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var updated = set
        var page = updated.pages[pageIndex]
        var views = page.effectiveSheetViews
        guard let viewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"]) else {
            return fail("bad_view_id", "viewID must be a sheet-view UUID string.")
        }
        guard views.contains(where: { $0.id == viewID }) else {
            return fail("unknown_view", "No sheet view with that id on this page.")
        }
        guard views.count > 1 else {
            return fail("last_view", "A sheet needs at least one view; remove the page instead.")
        }
        let danglingAnnotations = page.manualDimensions.filter { $0.viewID == viewID }.count
            + page.balloons.filter { $0.viewID == viewID }.count
            + page.annotations.filter { $0.viewID == viewID }.count
        if danglingAnnotations > 0 && !(boolValue(args["removeAnnotations"]) ?? false) {
            return fail("view_has_annotations",
                        "This view still owns \(danglingAnnotations) annotation(s). "
                        + "Move or remove them, or pass removeAnnotations=true.")
        }
        page.manualDimensions.removeAll { $0.viewID == viewID }
        page.balloons.removeAll { $0.viewID == viewID }
        page.annotations.removeAll { $0.viewID == viewID }
        views.removeAll { $0.id == viewID }
        // Re-home alignments that referenced the removed view rather than
        // leaving a permanently unresolved link.
        for index in views.indices where views[index].alignment.referenceViewID == viewID {
            views[index].alignment.referenceViewID = nil
            views[index].alignment.placement = .free
        }
        page.sheetViews = views
        updated.pages[pageIndex] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "page": pagePayload(page),
                "removedViewID": viewID.uuidString,
                "removedAnnotationCount": danglingAnnotations]
    }

    /// Recompute the sheet's base layout from live projected bounds. The first
    /// non-section view is the free anchor; the other standard views get their
    /// projection alignment relative to it. Explicit offsets become nudges of
    /// zero so the sheet snaps back to a coherent arrangement.
    private func layoutViewsAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let pageIndex = set.pages.firstIndex(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var updated = set
        var page = updated.pages[pageIndex]
        var views = page.effectiveSheetViews
        guard views.count > 1 else {
            return fail("not_multi_view", "layoutViews needs a page with several sheet views.")
        }
        var margin = 25.0
        if let raw = args["marginMM"] {
            guard let value = doubleValue(raw), value.isFinite, value >= 0, value <= 200 else {
                return fail("bad_margin", "marginMM must be a finite number in [0, 200].")
            }
            margin = value
        }
        var gap = 14.0
        if let raw = args["gapMM"] {
            guard let value = doubleValue(raw), value.isFinite, value >= 0, value <= 200 else {
                return fail("bad_gap", "gapMM must be a finite number in [0, 200].")
            }
            gap = value
        }
        let preview = projectSheetPreview(page)
        guard let anchorIndex = views.firstIndex(where: { $0.kind != .section }) else {
            return fail("no_anchor_view", "A sheet layout needs a non-section anchor view.")
        }
        let anchorID = views[anchorIndex].id
        guard let anchorBounds = preview.views.first(where: { $0.view.id == anchorID })?.localBounds else {
            return fail("empty_view", "The anchor view projected no geometry.")
        }
        views[anchorIndex].alignment = CADDrawingViewAlignment()
        views[anchorIndex].offset = SIMD2(margin - anchorBounds.min.x,
                                          150 - anchorBounds.min.y)
        for index in views.indices where index != anchorIndex {
            views[index].alignment.referenceViewID = anchorID
            views[index].alignment.gapMM = gap
            let placement: CADDrawingViewPlacement
            switch views[index].kind {
            case .top: placement = .above
            case .side, .detail, .iso, .exploded: placement = .right
            case .section, .front: placement = .below
            }
            views[index].alignment.placement = placement
            views[index].offset = .zero
        }
        page.sheetViews = views
        updated.pages[pageIndex] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "page": pagePayload(page),
                "views": page.effectiveSheetViews.map { viewPayload($0) }]
    }

    /// Build/validate one view. Omitted fields keep the existing value.
    private func buildSheetView(args: [String: Any],
                                existing: CADDrawingSheetView?,
                                page: CADDrawingPage,
                                views: [CADDrawingSheetView])
        -> Result<CADDrawingSheetView, CADDrawingServiceError> {
        let kind: CADDrawingViewKind
        if let raw = args["kind"] {
            guard let name = raw as? String, let parsed = CADDrawingViewKind(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_kind",
                    message: "kind must be front, top, side, iso, section, detail or exploded."))
            }
            kind = parsed
        } else if let existing {
            kind = existing.kind
        } else {
            return .failure(CADDrawingServiceError(
                code: "missing_kind", message: "addView needs a kind."))
        }
        var scale = existing?.scale ?? page.scale
        if let raw = args["scale"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0, value <= 1000 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_scale", message: "scale must be a finite number in (0, 1000]."))
            }
            scale = value
        }
        var offset = existing?.offset ?? .zero
        if let raw = args["nudge"] {
            guard let parsed = point2(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_offset", message: "nudge must be a finite [x,y] point."))
            }
            offset += parsed
        }
        var clearsAlignment = false
        if let raw = args["offset"] {
            guard let parsed = point2(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_offset", message: "offset must be a finite [x,y] point."))
            }
            offset = parsed
            clearsAlignment = args["alignmentPlacement"] == nil
        }
        var viewNormal = existing?.viewNormal ?? defaultViewNormal(for: kind)
        if let raw = args["viewNormal"] {
            guard let vector = vector3(raw), simd_length(vector) > 1e-9 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_view_normal", message: "viewNormal must be a non-zero finite [x,y,z]."))
            }
            viewNormal = simd_normalize(vector)
        }
        var viewUp = existing?.viewUp ?? SIMD3<Double>(0, 1, 0)
        if let raw = args["viewUp"] {
            guard let vector = vector3(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_view_up", message: "viewUp must be a finite [x,y,z]."))
            }
            viewUp = simd_length(vector) > 1e-9 ? simd_normalize(vector)
                                              : SIMD3<Double>(0, 1, 0)
        }
        var sectionOrigin = existing?.kind == .section ? existing?.sectionOrigin : nil
        var sectionNormal = existing?.kind == .section ? existing?.sectionNormal : nil
        var detailOrigin = existing?.kind == .detail ? existing?.detailOrigin : nil
        var detailSizeMM = existing?.kind == .detail ? existing?.detailSizeMM : nil
        if let raw = args["sectionOrigin"] {
            guard let vector = vector3(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_section_origin", message: "sectionOrigin must be a finite [x,y,z]."))
            }
            sectionOrigin = vector
        }
        if let raw = args["sectionNormal"] {
            guard let vector = vector3(raw), simd_length(vector) > 1e-9 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_section_normal", message: "sectionNormal must be a non-zero finite [x,y,z]."))
            }
            sectionNormal = simd_normalize(vector)
        }
        if kind == .section {
            guard sectionNormal != nil, sectionOrigin != nil else {
                return .failure(CADDrawingServiceError(
                    code: "missing_section_plane",
                    message: "section views need sectionOrigin and sectionNormal."))
            }
            if args["viewNormal"] == nil { viewNormal = sectionNormal! }
        }
        if kind == .detail {
            if let raw = args["detailOrigin"] {
                guard let vector = vector3(raw) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_detail_origin", message: "detailOrigin must be a finite [x,y,z]."))
                }
                detailOrigin = vector
            }
            if let raw = args["detailSizeMM"] {
                guard let size = sizeValue(raw), size.width > 0, size.height > 0 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_detail_size",
                        message: "detailSizeMM must be a positive number or [width, height]."))
                }
                detailSizeMM = SIMD2(size.width, size.height)
            }
            guard detailOrigin != nil, detailSizeMM != nil else {
                return .failure(CADDrawingServiceError(
                    code: "missing_detail_window",
                    message: "detail views need detailOrigin and detailSizeMM."))
            }
        }
        var sourceBodyIDs = existing?.sourceBodyIDs
        if sourceBodyIDs == nil, existing == nil,
           args["bodyIDs"] == nil, args["sourceBodyIDs"] == nil {
            sourceBodyIDs = page.effectiveSheetViews.first?.sourceBodyIDs
        }
        if let raw = args["bodyIDs"] ?? args["sourceBodyIDs"] {
            let strings: [String]
            if let list = raw as? [String] { strings = list }
            else if let one = raw as? String { strings = [one] }
            else {
                return .failure(CADDrawingServiceError(
                    code: "bad_body_ids", message: "bodyIDs must be an array of body UUID strings."))
            }
            var ids: [UUID] = []
            for string in strings {
                guard let id = UUID(uuidString: string), body(for: id) != nil else {
                    return .failure(CADDrawingServiceError(
                        code: "unknown_body", message: "bodyIDs must all reference live document bodies."))
                }
                ids.append(id)
            }
            guard ids.count <= Self.maxSourceBodies else {
                return .failure(CADDrawingServiceError(
                    code: "too_many_bodies",
                    message: "A view is bounded to \(Self.maxSourceBodies) source bodies."))
            }
            guard Set(ids).count == ids.count else {
                return .failure(CADDrawingServiceError(
                    code: "duplicate_body", message: "bodyIDs must not repeat."))
            }
            sourceBodyIDs = ids.isEmpty ? nil : ids
        }
        var alignment = existing?.alignment ?? CADDrawingViewAlignment()
        if clearsAlignment {
            alignment = CADDrawingViewAlignment()
        }
        if let raw = args["alignmentPlacement"] {
            guard let name = raw as? String,
                  let placement = CADDrawingViewPlacement(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_alignment",
                    message: "alignmentPlacement must be free, above, below, left or right."))
            }
            alignment.placement = placement
            if placement == .free { alignment.referenceViewID = nil }
        }
        if args.keys.contains("alignmentReferenceID") {
            let raw = args["alignmentReferenceID"]
            if raw == nil || raw is NSNull {
                alignment.referenceViewID = nil
            } else {
                guard let id = uuidValue(raw) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_alignment",
                        message: "alignmentReferenceID must be a sheet-view UUID."))
                }
                if let existingID = existing?.id, existingID == id {
                    return .failure(CADDrawingServiceError(
                        code: "bad_alignment", message: "A view cannot align to itself."))
                }
                guard views.contains(where: { $0.id == id }) else {
                    return .failure(CADDrawingServiceError(
                        code: "unknown_view",
                        message: "alignmentReferenceID does not reference a view on this page."))
                }
                alignment.referenceViewID = id
                if alignment.placement == .free { alignment.placement = .above }
            }
        }
        if alignment.placement != .free && alignment.referenceViewID == nil {
            return .failure(CADDrawingServiceError(
                code: "missing_alignment_reference",
                message: "An aligned view needs alignmentReferenceID."))
        }
        if let raw = args["gapMM"] {
            guard let value = doubleValue(raw), value.isFinite, value >= 0, value <= 500 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_gap", message: "gapMM must be a finite number in [0, 500]."))
            }
            alignment.gapMM = value
        }
        var name = existing?.name ?? kind.title
        if let raw = args["name"] {
            guard let value = raw as? String, !value.isEmpty else {
                return .failure(CADDrawingServiceError(
                    code: "bad_name", message: "name must be a non-empty string."))
            }
            name = value
        }
        return .success(CADDrawingSheetView(
            id: existing?.id ?? UUID(), name: name, kind: kind, scale: scale,
            offset: offset, viewNormal: viewNormal, viewUp: viewUp,
            sectionOrigin: sectionOrigin, sectionNormal: sectionNormal,
            detailOrigin: detailOrigin, detailSizeMM: detailSizeMM,
            sourceBodyIDs: sourceBodyIDs, alignment: alignment))
    }

    // MARK: - Export action

    private func exportAction(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let format = (args["format"] as? String)?.lowercased() else {
            return fail("missing_format", "format must be pdf, svg, dxf, png or csv.")
        }
        do {
            let data = try exportData(pageID: id, format: format)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return [
                "ok": true,
                "mutated": false,
                "pageID": id.uuidString,
                "format": format,
                "base64": data.base64EncodedString(),
                "byteCount": data.count,
                "sha256": digest,
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "noRasterization": true,
            ]
        } catch let error as CADDocumentError {
            return failurePayload(error)
        } catch {
            return fail("export_failed",
                        "The \(format) export failed: \(error.localizedDescription)")
        }
    }

    /// JSON-safe refusal with the service's exact code plus optional
    /// machine-readable context. Numeric context keys stay JSON numbers so a
    /// caller can distinguish "9 rows" from "capacity 6" without parsing the
    /// human-readable message.
    private func failurePayload(_ error: CADDocumentError) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": false,
            "error": error.code,
            "message": error.message,
        ]
        for (key, value) in error.details {
            if ["actualRows", "capacity", "requiredRows", "requiredColumns"].contains(key),
               let number = Int(value) {
                payload[key] = number
            } else {
                payload[key] = value
            }
        }
        return payload
    }

    // MARK: - Assembly sheet

    /// Build the five-page assembly-aware sheet (front/top/side/iso/exploded)
    /// from the SAME placed instances and optional exploded view. Paper,
    /// scale and title are page data and stay editable per page afterwards.
    private func assemblySheetAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let assembly = loadAssemblyValue(),
              assembly.occurrences(includeHidden: true).contains(where: { $0.isDrawablePart }) else {
            return fail("empty_assembly", "Place assembly instances before creating an assembly drawing sheet.")
        }
        var bodyIDs: [UUID] = []
        if let raw = args["bodyIDs"] ?? args["sourceBodyIDs"] {
            guard let strings = raw as? [String] else {
                return fail("bad_body_ids", "bodyIDs must be an array of body UUID strings.")
            }
            for string in strings {
                guard let id = UUID(uuidString: string), body(for: id) != nil else {
                    return fail("unknown_body", "bodyIDs must all reference live document bodies.")
                }
                bodyIDs.append(id)
            }
            guard bodyIDs.count <= Self.maxSourceBodies else {
                return fail("too_many_bodies",
                            "A page is bounded to \(Self.maxSourceBodies) source bodies.")
            }
            guard Set(bodyIDs).count == bodyIDs.count else {
                return fail("duplicate_body", "bodyIDs must not repeat.")
            }
        }
        var scale = 1.0
        if let raw = args["scale"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0, value <= 1000 else {
                return fail("bad_scale", "scale must be a finite number in (0, 1000].")
            }
            scale = value
        }
        var paper = CADPaperSize.a3
        if let raw = args["paper"] {
            guard let name = raw as? String, let parsed = CADPaperSize(rawValue: name) else {
                return fail("unknown_paper",
                            "paper must be a4, a3, a2, a1, a0, letter, tabloid or custom.")
            }
            paper = parsed
        }
        var explodedViewID: UUID?
        if let raw = args["explodedViewID"], !(raw is NSNull) {
            guard let id = uuidValue(raw), assembly.explodedView(id) != nil else {
                return fail("unknown_exploded_view",
                            "explodedViewID does not reference a stored exploded view.")
            }
            explodedViewID = id
        }
        let viewName = explodedViewID.flatMap { assembly.explodedView($0)?.name }
        let title = (args["title"] as? String) ?? document.name
        let sheet = CADDrawingSet.assemblySheet(bodyIDs: bodyIDs, title: title,
                                                explodedViewID: explodedViewID,
                                                explodedViewName: viewName,
                                                scale: scale, paper: paper)
        let replace = boolValue(args["replace"]) ?? false
        var pages = replace ? [] : set.pages
        pages.append(contentsOf: sheet.pages)
        guard pages.count <= Self.maxPages else {
            return fail("too_many_pages", "A drawing set is bounded to \(Self.maxPages) pages.")
        }
        var updated = set
        updated.pages = pages
        if let failure = persist(updated) { return failure }
        return [
            "ok": true,
            "mutated": true,
            "pageCount": updated.pages.count,
            "createdIDs": sheet.pages.map(\.id.uuidString),
            "pages": sheet.pages.map(pagePayload),
            "explodedViewID": (explodedViewID?.uuidString as Any?) ?? NSNull(),
        ]
    }

    // MARK: - BOM

    /// Derive (or explicitly replace) the page BOM. Shared instances of one
    /// part definition group into one row with a quantity; an independent
    /// copy owns its own body and therefore its own row.
    private func setBOMAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        let assembly = loadAssemblyValue()
        func cleanedText(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let rawEntries = args["entries"] as? [[String: Any]] {
            var entries: [CADDrawingBOMEntry] = []
            var numbers = Set<Int>()
            for raw in rawEntries {
                guard let number = intValue(raw["itemNumber"]), number > 0 else {
                    return fail("bad_item_number", "Every BOM entry needs a positive itemNumber.")
                }
                guard numbers.insert(number).inserted else {
                    return fail("duplicate_item_number", "BOM item numbers must be unique.")
                }
                guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    return fail("bad_bom_name", "Every BOM entry needs a non-empty name.")
                }
                guard let bodyID = uuidValue(raw["bodyID"]), body(for: bodyID) != nil else {
                    return fail("unknown_body", "Every BOM entry bodyID must reference a live body.")
                }
                var instanceIDs: [UUID] = []
                var seenInstances = Set<UUID>()
                if let rawIDs = raw["instanceIDs"] as? [String] {
                    for text in rawIDs {
                        guard let instanceID = UUID(uuidString: text),
                              let instance = assembly?.instance(instanceID) else {
                            return fail("unknown_instance",
                                        "BOM entry instanceIDs must reference live instances.")
                        }
                        if seenInstances.insert(instance.id).inserted {
                            instanceIDs.append(instance.id)
                        }
                    }
                }
                let instanceIdentities = Set(instanceIDs.compactMap {
                    assembly?.instance($0)?.bomIdentity
                })
                guard instanceIdentities.count <= 1 else {
                    return fail("mixed_part_instances",
                                "One BOM row must not mix instances of different part definitions.")
                }
                var partDefinitionID = uuidValue(raw["partDefinitionID"] ?? raw["definitionID"])
                if let requested = partDefinitionID {
                    let live = Set((assembly?.occurrences(includeHidden: true) ?? [])
                        .filter { !$0.instance.isSubassembly }
                        .map(\.bomIdentity))
                    guard live.contains(requested) else {
                        return fail("unknown_part",
                                    "partDefinitionID must name a live part definition.")
                    }
                    if !instanceIdentities.isEmpty,
                       instanceIdentities != Set([requested]) {
                        return fail("part_definition_mismatch",
                                    "partDefinitionID does not match the supplied instances.")
                    }
                } else {
                    partDefinitionID = instanceIdentities.first
                }
                let quantity = intValue(raw["quantity"]) ?? max(instanceIDs.count, 1)
                guard quantity > 0 else {
                    return fail("bad_quantity", "BOM quantity must be positive.")
                }
                let metadata = partDefinitionID.flatMap {
                    assembly?.partMetadataRecord($0)
                }
                entries.append(CADDrawingBOMEntry(
                    id: uuidValue(raw["id"]) ?? UUID(),
                    itemNumber: number,
                    name: name,
                    partNumber: (raw["partNumber"] as? String)
                        ?? metadata?.partNumber ?? "",
                    bodyID: bodyID,
                    instanceIDs: instanceIDs,
                    quantity: quantity,
                    partDefinitionID: partDefinitionID,
                    material: cleanedText(raw["material"]) ?? metadata?.material,
                    version: cleanedText(raw["version"]) ?? metadata?.version))
            }
            entries.sort { $0.itemNumber < $1.itemNumber }
            page.bom = CADDrawingBOM(entries: entries)
            page.showBOM = boolValue(args["showBOM"]) ?? true
            var updated = set
            updated.pages[index] = page
            if let failure = persist(updated) { return failure }
            var reply = bomReply(page: page, assembly: assembly)
            reply["mutated"] = true
            return reply
        }

        guard let assembly else {
            return fail("empty_assembly", "There is no assembly data to derive a BOM from.")
        }
        let filter = Set(page.sourceBodyIDs)
        // Stable row identity/numbers survive a re-derive. New rows key on the
        // part definition; legacy rows without one also retain their old
        // body-id key so a shared external reference's staged body can still
        // adopt the original row instead of renumbering it.
        var oldByPart: [UUID: CADDrawingBOMEntry] = [:]
        var oldByBody: [UUID: CADDrawingBOMEntry] = [:]
        for old in page.bom?.entries ?? [] {
            if oldByPart[old.resolvedPartDefinitionID] == nil {
                oldByPart[old.resolvedPartDefinitionID] = old
            }
            if oldByBody[old.bodyID] == nil { oldByBody[old.bodyID] = old }
        }
        var groups: [(identity: UUID, bodyID: UUID, instances: [CADAssemblyInstance])] = []
        var indexByIdentity: [UUID: Int] = [:]
        // Nested subassembly leaves participate in the BOM exactly like flat
        // instances. Grouping uses the occurrence's stable `bomIdentity`, not
        // a name or geometry match: shared instances of one definition count
        // together, and an independent copy (different identity) stays its own
        // row even when its source geometry is identical.
        for occurrence in assembly.occurrences(includeHidden: false) {
            guard occurrence.isDrawablePart, let bodyID = occurrence.effectiveBodyID else { continue }
            let instance = occurrence.instance
            guard filter.isEmpty || filter.contains(bodyID) else { continue }
            let identity = occurrence.bomIdentity
            if let existing = indexByIdentity[identity] {
                if !groups[existing].instances.contains(where: { $0.id == instance.id }) {
                    groups[existing].instances.append(instance)
                }
            } else {
                indexByIdentity[identity] = groups.count
                groups.append((identity, bodyID, [instance]))
            }
        }
        guard !groups.isEmpty else {
            return fail("empty_bom", "No visible instance matches this page's source bodies.")
        }
        var usedNumbers = Set<Int>()
        for old in page.bom?.entries ?? [] { usedNumbers.insert(old.itemNumber) }
        var nextNumber = 1
        var entries: [CADDrawingBOMEntry] = []
        for group in groups {
            let bodyName = body(for: group.bodyID)?.name
            let name = bodyName ?? group.instances.first?.name ?? "Part"
            let old = oldByPart[group.identity] ?? oldByBody[group.bodyID]
            let metadata = assembly.partMetadataRecord(group.identity)
            // Legacy explicit rows keep their captured values; a row that
            // already binds a definition follows the live record (including a
            // cleared record) instead of resurrecting old text.
            let carryLegacyFields = old?.partDefinitionID == nil
            var number = old?.itemNumber ?? 0
            if number <= 0 {
                while usedNumbers.contains(nextNumber) { nextNumber += 1 }
                number = nextNumber
                usedNumbers.insert(number)
            }
            entries.append(CADDrawingBOMEntry(
                id: old?.id ?? UUID(),
                itemNumber: number,
                name: name,
                partNumber: metadata?.partNumber
                    ?? (carryLegacyFields ? old?.partNumber : nil) ?? "",
                bodyID: group.bodyID,
                instanceIDs: group.instances.map(\.id),
                quantity: group.instances.count,
                partDefinitionID: group.identity,
                material: metadata?.material
                    ?? (carryLegacyFields ? old?.material : nil),
                version: metadata?.version
                    ?? (carryLegacyFields ? old?.version : nil)))
        }
        entries.sort { $0.itemNumber < $1.itemNumber }
        page.bom = CADDrawingBOM(entries: entries)
        page.showBOM = boolValue(args["showBOM"]) ?? true
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        var reply = bomReply(page: page, assembly: assembly)
        reply["ok"] = true
        reply["mutated"] = true
        return reply
    }

    // MARK: - Balloons

    private func addBalloonAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard page.balloons.count < 128 else {
            return fail("too_many_balloons", "A page is bounded to 128 balloons.")
        }
        let requestedViewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"])
        if page.isMultiViewSheet && requestedViewID == nil {
            return fail("view_required",
                        "A multi-view sheet needs viewID so the balloon belongs to one view.")
        }
        if let requestedViewID,
           !page.effectiveSheetViews.contains(where: { $0.id == requestedViewID }) {
            return fail("unknown_view", "viewID does not reference a view on this page.")
        }
        let assembly = loadAssemblyValue()
        var itemNumber = intValue(args["itemNumber"]) ?? 0
        var bomEntryID = uuidValue(args["bomEntryID"])
        if let bomEntryID, let entry = page.bom?.entry(id: bomEntryID) {
            itemNumber = entry.itemNumber
        } else if bomEntryID != nil {
            return fail("unknown_bom_item", "bomEntryID does not reference this page's BOM.")
        }
        if itemNumber <= 0 {
            return fail("bad_item_number", "A balloon needs a positive itemNumber or a BOM entry.")
        }
        if let bom = page.bom, !bom.entries.isEmpty {
            guard let entry = bom.entry(itemNumber: itemNumber) else {
                return fail("unknown_bom_item",
                            "Item \(itemNumber) is not in this page's BOM; refresh the BOM first.")
            }
            bomEntryID = entry.id
        }
        var instance: CADAssemblyInstance?
        if let instanceID = uuidValue(args["instanceID"]) {
            guard let live = assembly?.instance(instanceID) else {
                return fail("unknown_instance", "instanceID must reference a live assembly instance.")
            }
            instance = live
        } else if let bomEntryID, let entry = page.bom?.entry(id: bomEntryID),
                  let firstID = entry.instanceIDs.first {
            instance = assembly?.instance(firstID)
        }
        guard let instance else {
            return fail("missing_instance",
                        "A balloon needs an assembly instance (or a BOM item with instances).")
        }
        let projection = projectPage(page)
        let anchor: SIMD2<Double>
        if let raw = args["anchor"] {
            guard let parsed = point2(raw) else {
                return fail("bad_anchor", "anchor must be a finite [x,y] drawing point.")
            }
            anchor = parsed
        } else {
            anchor = autoBalloonAnchor(instanceID: instance.id,
                                       page: page, projection: projection,
                                       viewID: requestedViewID)
        }
        var target: SIMD2<Double>?
        if let raw = args["target"], !(raw is NSNull) {
            guard let parsed = point2(raw) else {
                return fail("bad_target", "target must be a finite [x,y] drawing point.")
            }
            target = parsed
        }
        let balloon = CADDrawingBalloon(
            id: UUID(),
            itemNumber: itemNumber,
            bomEntryID: bomEntryID,
            instanceID: instance.id,
            anchor: anchor,
            target: target,
            text: args["text"] as? String,
            viewID: requestedViewID)
        page.balloons.append(balloon)
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let rows = resolvedBalloons(page: page, projection: projection)
        var reply: [String: Any] = ["ok": true, "mutated": true,
                                    "balloon": rows.first { ($0["id"] as? String) == balloon.id.uuidString } ?? [:]]
        reply["balloons"] = rows
        return reply
    }

    private func updateBalloonAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let balloonID = uuidValue(args["balloonID"]) ?? uuidValue(args["balloonId"]),
              let balloonIndex = page.balloons.firstIndex(where: { $0.id == balloonID }) else {
            return fail("unknown_balloon", "No balloon with that id on this page.")
        }
        var balloon = page.balloons[balloonIndex]
        if let raw = args["anchor"] {
            guard let parsed = point2(raw) else {
                return fail("bad_anchor", "anchor must be a finite [x,y] drawing point.")
            }
            balloon.anchor = parsed
        }
        if args.keys.contains("target") {
            if args["target"] == nil || args["target"] is NSNull {
                balloon.target = nil
            } else {
                guard let parsed = point2(args["target"]) else {
                    return fail("bad_target", "target must be a finite [x,y] drawing point.")
                }
                balloon.target = parsed
            }
        }
        if let text = args["text"] as? String {
            balloon.text = text
        }
        if let number = intValue(args["itemNumber"]), number > 0 {
            balloon.itemNumber = number
            balloon.bomEntryID = page.bom?.entry(itemNumber: number)?.id
        }
        if let instanceID = uuidValue(args["instanceID"]) {
            guard loadAssemblyValue()?.instance(instanceID) != nil else {
                return fail("unknown_instance", "instanceID must reference a live assembly instance.")
            }
            balloon.instanceID = instanceID
        }
        page.balloons[balloonIndex] = balloon
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let rows = resolvedBalloons(page: page, projection: projectPage(page))
        return ["ok": true, "mutated": true,
                "balloon": rows.first { ($0["id"] as? String) == balloon.id.uuidString } ?? [:],
                "balloons": rows]
    }

    private func removeBalloonAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let balloonID = uuidValue(args["balloonID"]) ?? uuidValue(args["balloonId"]),
              page.balloons.contains(where: { $0.id == balloonID }) else {
            return fail("unknown_balloon", "No balloon with that id on this page.")
        }
        page.balloons.removeAll { $0.id == balloonID }
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true, "removedBalloon": balloonID.uuidString,
                "balloonCount": page.balloons.count]
    }

    // MARK: - Manual dimensions

    private func addDimensionAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard page.manualDimensions.count < 128 else {
            return fail("too_many_dimensions", "A page is bounded to 128 manual dimensions.")
        }
        guard let rawKind = args["kind"] as? String,
              let kind = CADDrawingDimensionKind(rawValue: rawKind) else {
            return fail("unknown_dimension_kind",
                        "kind must be length, angle, radius or diameter.")
        }
        let requestedViewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"])
        if page.isMultiViewSheet && requestedViewID == nil {
            return fail("view_required",
                        "A multi-view sheet needs viewID so the annotation belongs to one view.")
        }
        let view: CADDrawingSheetView
        if let requestedViewID {
            guard let found = page.effectiveSheetViews.first(where: { $0.id == requestedViewID }) else {
                return fail("unknown_view", "viewID does not reference a view on this page.")
            }
            view = found
        } else {
            view = page.effectiveSheetViews[0]
        }
        let viewPlane = plane(for: page, view: view)
        let scale = view.scale
        let context = ResolvedViewContext(view: view, offset: .zero, plane: viewPlane,
                                          scale: scale, isLegacy: page.sheetViews == nil)
        let required = kind == .angle ? 3 : 2

        if let rawFeature = args["feature"], !(rawFeature is NSNull) {
            guard kind == .diameter || kind == .radius else {
                return fail("unsupported_reference",
                            "A linked feature dimension supports only diameter or radius; "
                            + "source-relative length/angle dimensions are not implemented.")
            }
            let feature: CADDrawingFeatureReference
            switch parseFeatureReference(rawFeature, page: page) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed): feature = parsed
            }
            let resolved: ResolvedFeatureFace
            switch resolveFeatureFace(feature, page: page, context: context) {
            case .failure(let message):
                return fail("stale_feature_reference", message)
            case .success(let face): resolved = face
            }
            let direction = SIMD2<Double>(1, 0)
            let drawingPoints = [resolved.drawingCenter,
                                 resolved.drawingCenter + direction * resolved.drawingRadius]
            let value = kind == .diameter ? resolved.radiusMM * 2 : resolved.radiusMM
            var textPosition: SIMD2<Double>
            if let raw = args["textPosition"] {
                guard let parsed = point2(raw) else {
                    return fail("bad_text_position", "textPosition must be a finite [x,y] point.")
                }
                textPosition = parsed
            } else {
                textPosition = defaultDimensionTextPosition(kind: kind, points: drawingPoints)
            }
            let tolerance: CADDrawingTolerance?
            switch parseTolerance(args["tolerance"], kind: kind, nominal: value) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed): tolerance = parsed
            }
            let dimension = CADDrawingManualDimension(
                id: UUID(), kind: kind, drawingPoints: drawingPoints, value: value,
                textPosition: textPosition,
                textOverride: args["text"] as? String, binding: nil,
                viewID: requestedViewID, feature: feature,
                tolerance: tolerance)
            page.manualDimensions.append(dimension)
            var updated = set
            updated.pages[index] = page
            if let failure = persist(updated) { return failure }
            let resolvedRows = resolvedManualDimensions(page: page, projection: projectPage(page))
            return ["ok": true, "mutated": true,
                    "dimension": resolvedRows.rows.first {
                        ($0["id"] as? String) == dimension.id.uuidString
                    } ?? [:],
                    "manualDimensions": resolvedRows.rows]
        }

        var drawingPoints: [SIMD2<Double>] = []
        if let raw = args["drawingPoints"] {
            guard let rows = raw as? [[Double]] else {
                return fail("bad_points", "drawingPoints must be an array of [x,y] points.")
            }
            guard rows.count == required else {
                return fail("bad_points", "\(kind.rawValue) needs \(required) drawing points.")
            }
            drawingPoints = rows.compactMap { row in
                row.count == 2 && row.allSatisfy(\.isFinite)
                    ? SIMD2<Double>(row[0], row[1]) : nil
            }
            guard drawingPoints.count == required else {
                return fail("bad_points", "drawingPoints must all be finite [x,y] pairs.")
            }
        }
        var modelPoints: [SIMD3<Double>] = []
        if let raw = args["modelPoints"] {
            guard let rows = raw as? [[Double]] else {
                return fail("bad_model_points", "modelPoints must be an array of [x,y,z] points.")
            }
            guard rows.count == required else {
                return fail("bad_model_points",
                            "\(kind.rawValue) needs \(required) body-local model points.")
            }
            modelPoints = rows.compactMap { row in
                row.count == 3 && row.allSatisfy(\.isFinite)
                    ? SIMD3<Double>(row[0], row[1], row[2]) : nil
            }
            guard modelPoints.count == required else {
                return fail("bad_model_points",
                            "modelPoints must all be finite [x,y,z] pairs.")
            }
        }
        if modelPoints.isEmpty && drawingPoints.isEmpty {
            return fail("bad_points",
                        "Provide drawingPoints (view space), modelPoints with an instance binding, "
                        + "or a feature reference.")
        }
        var instance: CADAssemblyInstance?
        var source: Body?
        if let instanceID = uuidValue(args["instanceID"]) {
            guard let live = loadAssemblyValue()?.instance(instanceID) else {
                return fail("unknown_instance", "instanceID must reference a live assembly instance.")
            }
            guard let body = body(for: effectiveBodyID(live)) else {
                return fail("unknown_body", "The instance's source body no longer resolves.")
            }
            instance = live
            source = body
        }
        if !modelPoints.isEmpty, instance == nil {
            return fail("missing_instance",
                        "Body-local modelPoints need an assembly instance frame.")
        }
        if modelPoints.isEmpty {
            guard let viewPlane else {
                return fail("bad_view_direction", "The view's direction is invalid.")
            }
            guard let instance, let source else {
                return fail("missing_instance",
                            "A dimension from drawing points must reference an assembly instance; "
                            + "pass modelPoints with a view-local frame only when bound.")
            }
            guard let world = instanceWorldTransform(instance: instance, source: source, page: page) else {
                return fail("unknown_instance", "The instance transform is not placeable.")
            }
            for point in drawingPoints {
                guard let local = bodyLocalPointFromDrawing(point, plane: viewPlane,
                                                           scale: scale, world: world,
                                                           source: source) else {
                    return fail("bad_points", "A drawing point could not be mapped onto the part.")
                }
                modelPoints.append(local)
            }
        } else if drawingPoints.isEmpty {
            guard let viewPlane, let instance, let source,
                  let world = instanceWorldTransform(instance: instance, source: source, page: page) else {
                return fail("bad_points",
                            "The view or instance transform cannot project the model points.")
            }
            for point in modelPoints {
                guard let drawing = drawingPointFromBodyLocal(point, plane: viewPlane,
                                                              scale: scale, world: world) else {
                    return fail("bad_points", "A model point could not be projected.")
                }
                drawingPoints.append(drawing)
            }
        }
        let value: Double
        switch kind {
        case .length:
            value = simd_distance(modelPoints[0], modelPoints[1])
        case .angle:
            let a = modelPoints[1] - modelPoints[0]
            let b = modelPoints[2] - modelPoints[0]
            guard simd_length(a) > 1e-12, simd_length(b) > 1e-12 else {
                return fail("bad_points", "Angle references need two non-zero rays.")
            }
            value = acos(min(max(simd_dot(simd_normalize(a), simd_normalize(b)), -1), 1))
                * 180 / .pi
        case .radius:
            value = simd_distance(modelPoints[0], modelPoints[1])
        case .diameter:
            value = simd_distance(modelPoints[0], modelPoints[1]) * 2
        }
        guard value.isFinite, value >= 0 else {
            return fail("bad_value", "The dimension value is not finite.")
        }
        let tolerance: CADDrawingTolerance?
        switch parseTolerance(args["tolerance"], kind: kind, nominal: value) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): tolerance = parsed
        }
        var textPosition: SIMD2<Double>
        if let raw = args["textPosition"] {
            guard let parsed = point2(raw) else {
                return fail("bad_text_position", "textPosition must be a finite [x,y] point.")
            }
            textPosition = parsed
        } else {
            textPosition = defaultDimensionTextPosition(kind: kind, points: drawingPoints)
        }
        let binding = instance.flatMap { instance -> CADDrawingBinding? in
            guard let source else { return nil }
            return CADDrawingBinding(instanceID: instance.id,
                                     bodyID: source.id.raw,
                                     modelPoints: modelPoints,
                                     sourceRevision: source.meshRevision)
        }
        let dimension = CADDrawingManualDimension(
            id: UUID(), kind: kind, drawingPoints: drawingPoints, value: value,
            textPosition: textPosition,
            textOverride: args["text"] as? String, binding: binding,
            viewID: requestedViewID, feature: nil,
            tolerance: tolerance)
        page.manualDimensions.append(dimension)
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let resolved = resolvedManualDimensions(page: page, projection: projectPage(page))
        return ["ok": true, "mutated": true,
                "dimension": resolved.rows.first { ($0["id"] as? String) == dimension.id.uuidString } ?? [:],
                "manualDimensions": resolved.rows]
    }

    private func parseFeatureReference(_ raw: Any, page: CADDrawingPage)
        -> Result<CADDrawingFeatureReference, CADDrawingServiceError> {
        var dict = raw as? [String: Any] ?? [:]
        if let nested = dict["reference"] as? [String: Any] { dict = nested }
        if dict["provenanceAmbiguity"] as? Bool == true,
           uuidValue(dict["featureID"]) == nil
            || uuidValue(dict["sketchID"]) == nil
            || uuidValue(dict["sketchEntityID"]) == nil {
            return .failure(CADDrawingServiceError(
                code: "ambiguous_feature_reference",
                message: "Select the source feature, sketch and circle for this dimension."))
        }
        guard let bodyID = uuidValue(dict["bodyID"]) else {
            return .failure(CADDrawingServiceError(
                code: "bad_feature_reference", message: "feature.bodyID is required."))
        }
        guard body(for: bodyID) != nil else {
            return .failure(CADDrawingServiceError(
                code: "unknown_body", message: "feature.bodyID must reference a live body."))
        }
        let instanceID = uuidValue(dict["instanceID"])
        if let instanceID, loadAssemblyValue()?.instance(instanceID) == nil {
            return .failure(CADDrawingServiceError(
                code: "unknown_instance", message: "feature.instanceID must reference a live instance."))
        }
        guard let anchor = dict["anchor"] as? [String: Any],
              let centroid = vector3(anchor["centroid"]),
              let direction = vector3(anchor["direction"]),
              simd_length(direction) > 1e-9 else {
            return .failure(CADDrawingServiceError(
                code: "bad_feature_reference",
                message: "feature.anchor needs a finite centroid and non-zero direction."))
        }
        let kind: CADDrawingFeatureKind
        if let rawKind = dict["kind"] as? String {
            guard let parsed = CADDrawingFeatureKind(rawValue: rawKind) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_feature_reference",
                    message: "feature.kind must be cylindricalFace."))
            }
            kind = parsed
        } else {
            kind = .cylindricalFace
        }
        let tolerance = doubleValue(anchor["toleranceMM"]) ?? 0.5
        guard tolerance.isFinite, tolerance > 0, tolerance <= 10 else {
            return .failure(CADDrawingServiceError(
                code: "bad_feature_reference",
                message: "feature.anchor.toleranceMM must be in (0, 10]."))
        }
        let radius = doubleValue(anchor["radiusMM"])
        let sourceRevision = (dict["sourceRevision"] as? UInt64)
            ?? (dict["sourceRevision"] as? Int).map { UInt64($0) }
            ?? (dict["sourceRevision"] as? NSNumber)?.uint64Value
        return .success(CADDrawingFeatureReference(
            kind: kind, bodyID: bodyID, instanceID: instanceID,
            anchor: CADDrawingFeatureAnchor(centroid: centroid,
                                            direction: simd_normalize(direction),
                                            radiusMM: radius,
                                            toleranceMM: tolerance),
            featureID: uuidValue(dict["featureID"]),
            sketchID: uuidValue(dict["sketchID"]),
            sketchEntityID: uuidValue(dict["sketchEntityID"]),
            sourceRevision: sourceRevision))
    }

    /// Parse and validate a structured dimension tolerance. `null`/absent
    /// clears it. The values are model millimetres (degrees for an angle) and
    /// are never derived from the text override.
    private func parseTolerance(_ raw: Any?, kind: CADDrawingDimensionKind,
                                nominal: Double)
        -> Result<CADDrawingTolerance?, CADDrawingServiceError> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        guard let dict = raw as? [String: Any],
              let kindRaw = dict["kind"] as? String,
              let toleranceKind = CADDrawingToleranceKind(rawValue: kindRaw) else {
            return .failure(CADDrawingServiceError(
                code: "bad_tolerance",
                message: "tolerance.kind must be symmetric, deviation, limits or fit."))
        }
        func finite(_ key: String) -> Double? {
            guard let raw = dict[key] else { return nil }
            return doubleValue(raw)
        }
        var tolerance = CADDrawingTolerance(kind: toleranceKind)
        switch toleranceKind {
        case .symmetric:
            guard let deviation = finite("deviationMM") else {
                return .failure(CADDrawingServiceError(
                    code: "bad_tolerance",
                    message: "A symmetric tolerance needs deviationMM."))
            }
            tolerance.deviationMM = deviation
        case .deviation:
            guard let upper = finite("upperDeviationMM"),
                  let lower = finite("lowerDeviationMM") else {
                return .failure(CADDrawingServiceError(
                    code: "bad_tolerance",
                    message: "A deviation tolerance needs upperDeviationMM and lowerDeviationMM."))
            }
            tolerance.upperDeviationMM = upper
            tolerance.lowerDeviationMM = lower
        case .limits:
            guard let upper = finite("upperLimitMM"),
                  let lower = finite("lowerLimitMM") else {
                return .failure(CADDrawingServiceError(
                    code: "bad_tolerance",
                    message: "A limits tolerance needs upperLimitMM and lowerLimitMM."))
            }
            tolerance.upperLimitMM = upper
            tolerance.lowerLimitMM = lower
        case .fit:
            guard let fit = dict["fit"] as? [String: Any],
                  let holeGrade = intValue(fit["holeGrade"]),
                  let shaftLetter = fit["shaftLetter"] as? String,
                  let shaftGrade = intValue(fit["shaftGrade"]) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_tolerance",
                    message: "A fit tolerance needs fit.holeGrade, fit.shaftLetter and fit.shaftGrade."))
            }
            tolerance.fit = CADDrawingISO286Fit(holeGrade: holeGrade,
                                                shaftLetter: shaftLetter,
                                                shaftGrade: shaftGrade)
        }
        let issues = CADDrawingManufacturingRules.validateTolerance(tolerance,
                                                                    kind: kind,
                                                                    nominal: nominal)
        guard issues.isEmpty else {
            return .failure(CADDrawingServiceError(
                code: "invalid_tolerance", message: issues.joined(separator: " ")))
        }
        return .success(tolerance)
    }

    private func tolerancePayload(_ tolerance: CADDrawingTolerance) -> [String: Any] {
        var object: [String: Any] = ["kind": tolerance.kind.rawValue]
        if let value = tolerance.deviationMM { object["deviationMM"] = value }
        if let value = tolerance.upperDeviationMM { object["upperDeviationMM"] = value }
        if let value = tolerance.lowerDeviationMM { object["lowerDeviationMM"] = value }
        if let value = tolerance.upperLimitMM { object["upperLimitMM"] = value }
        if let value = tolerance.lowerLimitMM { object["lowerLimitMM"] = value }
        if let fit = tolerance.fit {
            object["fit"] = [
                "holeGrade": fit.holeGrade,
                "shaftLetter": fit.shaftLetter,
                "shaftGrade": fit.shaftGrade,
            ]
        }
        return object
    }

    private func toleranceDisplayPayload(_ display: CADDrawingToleranceDisplay) -> [String: Any] {
        var object: [String: Any] = [
            "lines": display.lines,
            "consistentWithNominal": display.consistentWithNominal,
        ]
        if let suffix = display.primarySuffix { object["primarySuffix"] = suffix }
        if let designation = display.designation { object["designation"] = designation }
        if let value = display.upperLimitMM { object["upperLimitMM"] = value }
        if let value = display.lowerLimitMM { object["lowerLimitMM"] = value }
        if let value = display.upperDeviationMM { object["upperDeviationMM"] = value }
        if let value = display.lowerDeviationMM { object["lowerDeviationMM"] = value }
        if let value = display.minClearanceMM { object["minClearanceMM"] = value }
        if let value = display.maxClearanceMM { object["maxClearanceMM"] = value }
        return object
    }

    private func updateDimensionAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let dimensionID = uuidValue(args["dimensionID"]),
              let dimensionIndex = page.manualDimensions.firstIndex(where: { $0.id == dimensionID }) else {
            return fail("unknown_dimension", "No manual dimension with that id on this page.")
        }
        var dimension = page.manualDimensions[dimensionIndex]
        if let raw = args["textPosition"] {
            guard let parsed = point2(raw) else {
                return fail("bad_text_position", "textPosition must be a finite [x,y] point.")
            }
            dimension.textPosition = parsed
        }
        if args.keys.contains("text") {
            dimension.textOverride = args["text"] as? String
        }
        if args.keys.contains("tolerance") {
            switch parseTolerance(args["tolerance"], kind: dimension.kind,
                                   nominal: dimension.value) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed): dimension.tolerance = parsed
            }
        }
        page.manualDimensions[dimensionIndex] = dimension
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let resolved = resolvedManualDimensions(page: page, projection: projectPage(page))
        return ["ok": true, "mutated": true,
                "dimension": resolved.rows.first { ($0["id"] as? String) == dimension.id.uuidString } ?? [:],
                "manualDimensions": resolved.rows]
    }

    private func removeDimensionAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let dimensionID = uuidValue(args["dimensionID"]),
              page.manualDimensions.contains(where: { $0.id == dimensionID }) else {
            return fail("unknown_dimension", "No manual dimension with that id on this page.")
        }
        page.manualDimensions.removeAll { $0.id == dimensionID }
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true, "removedDimension": dimensionID.uuidString,
                "manualDimensionCount": page.manualDimensions.count]
    }

    // MARK: - Manufacturing annotations (schema v5)

    private func addManufacturingAnnotationAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard page.manufacturingAnnotations.count < 128 else {
            return fail("too_many_manufacturing_annotations",
                        "A page is bounded to 128 manufacturing annotations.")
        }
        guard let rawKind = args["kind"] as? String,
              let kind = CADDrawingManufacturingKind(rawValue: rawKind) else {
            return fail("unknown_manufacturing_kind",
                        "kind must be datumFeature, featureControlFrame, surfaceFinish, "
                        + "weld, threadCallout or counterboreCallout.")
        }
        guard let position = point2(args["position"]) else {
            return fail("bad_position", "position must be a finite [x,y] view point.")
        }
        let requestedViewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"])
        if page.isMultiViewSheet && requestedViewID == nil {
            return fail("view_required",
                        "A multi-view sheet needs viewID so the annotation belongs to one view.")
        }
        if let requestedViewID,
           !page.effectiveSheetViews.contains(where: { $0.id == requestedViewID }) {
            return fail("unknown_view", "viewID does not reference a view on this page.")
        }
        let context = viewContext(for: page, projection: PageProjection(),
                                  viewID: requestedViewID)
        var feature: CADDrawingFeatureReference?
        if let rawFeature = args["feature"], !(rawFeature is NSNull) {
            switch parseFeatureReference(rawFeature, page: page) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed):
                if case .failure(let message) = resolveFeatureFace(
                    parsed, page: page, context: context,
                    allowLiveProvenanceStationDrift: true) {
                    return fail("stale_feature_reference", message)
                }
                feature = parsed
            }
        }
        let annotation: CADDrawingManufacturingAnnotation
        switch buildManufacturingAnnotation(kind: kind, args: args, base: nil,
                                            feature: feature, position: position,
                                            viewID: requestedViewID, context: context) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): annotation = parsed
        }
        page.manufacturingAnnotations.append(annotation)
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let rows = resolvedManufacturingAnnotations(page: page,
                                                    projection: projectPage(page))
        return ["ok": true, "mutated": true,
                "manufacturingAnnotation": rows.first {
                    ($0["id"] as? String) == annotation.id.uuidString
                } ?? [:],
                "manufacturingAnnotations": rows]
    }

    private func updateManufacturingAnnotationAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let annotationID = uuidValue(args["annotationID"]),
              let annotationIndex = page.manufacturingAnnotations.firstIndex(where: {
                  $0.id == annotationID
              }) else {
            return fail("unknown_manufacturing_annotation",
                        "No manufacturing annotation with that id on this page.")
        }
        if let rawKind = args["kind"] as? String,
           rawKind != page.manufacturingAnnotations[annotationIndex].kind.rawValue {
            return fail("kind_immutable",
                        "A manufacturing annotation's kind cannot change; add a new annotation instead.")
        }
        let existing = page.manufacturingAnnotations[annotationIndex]
        let requestedViewID = existing.viewID
        let context = viewContext(for: page, projection: PageProjection(),
                                  viewID: requestedViewID)
        var feature = existing.feature
        if args.keys.contains("feature") {
            let rawFeature = args["feature"]
            if rawFeature == nil || rawFeature is NSNull {
                feature = nil
            } else {
                switch parseFeatureReference(rawFeature!, page: page) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed):
                    if case .failure(let message) = resolveFeatureFace(
                        parsed, page: page, context: context,
                        allowLiveProvenanceStationDrift: true) {
                        return fail("stale_feature_reference", message)
                    }
                    feature = parsed
                }
            }
        }
        var position = existing.position
        if let raw = args["position"] {
            guard let parsed = point2(raw) else {
                return fail("bad_position", "position must be a finite [x,y] view point.")
            }
            position = parsed
        }
        let annotation: CADDrawingManufacturingAnnotation
        switch buildManufacturingAnnotation(kind: existing.kind, args: args, base: existing,
                                            feature: feature, position: position,
                                            viewID: requestedViewID, context: context) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): annotation = parsed
        }
        page.manufacturingAnnotations[annotationIndex] = annotation
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let rows = resolvedManufacturingAnnotations(page: page,
                                                    projection: projectPage(page))
        return ["ok": true, "mutated": true,
                "manufacturingAnnotation": rows.first {
                    ($0["id"] as? String) == annotation.id.uuidString
                } ?? [:],
                "manufacturingAnnotations": rows]
    }

    private func removeManufacturingAnnotationAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let pageID = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == pageID }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let annotationID = uuidValue(args["annotationID"]),
              page.manufacturingAnnotations.contains(where: { $0.id == annotationID }) else {
            return fail("unknown_manufacturing_annotation",
                        "No manufacturing annotation with that id on this page.")
        }
        page.manufacturingAnnotations.removeAll { $0.id == annotationID }
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "removedManufacturingAnnotation": annotationID.uuidString,
                "manufacturingAnnotationCount": page.manufacturingAnnotations.count]
    }

    private func buildManufacturingAnnotation(
        kind: CADDrawingManufacturingKind,
        args: [String: Any],
        base: CADDrawingManufacturingAnnotation?,
        feature: CADDrawingFeatureReference?,
        position: SIMD2<Double>,
        viewID: UUID?,
        context: ResolvedViewContext
    ) -> Result<CADDrawingManufacturingAnnotation, CADDrawingServiceError> {
        var height = base?.heightMM ?? 3.0
        if let raw = args["heightMM"] {
            guard let value = doubleValue(raw), value.isFinite,
                  (0.5...50).contains(value) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_height", message: "heightMM must be in [0.5, 50]."))
            }
            height = value
        }
        var annotation = CADDrawingManufacturingAnnotation(
            id: base?.id ?? UUID(), kind: kind, viewID: viewID,
            position: position, heightMM: height, feature: feature)
        let payloadKey: String
        switch kind {
        case .datumFeature: payloadKey = "datum"
        case .featureControlFrame: payloadKey = "featureControlFrame"
        case .surfaceFinish: payloadKey = "surfaceFinish"
        case .weld: payloadKey = "weld"
        case .threadCallout: payloadKey = "thread"
        case .counterboreCallout: payloadKey = "counterbore"
        }
        let allPayloadKeys = ["datum", "featureControlFrame", "surfaceFinish",
                              "weld", "thread", "counterbore"]
        if let wrong = allPayloadKeys.first(where: { $0 != payloadKey && args.keys.contains($0) }) {
            return .failure(CADDrawingServiceError(
                code: "payload_kind_mismatch",
                message: "A \(kind.rawValue) annotation cannot carry a \(wrong) payload."))
        }
        let rawPayload: Any?
        if args.keys.contains(payloadKey) {
            rawPayload = args[payloadKey]
        } else {
            rawPayload = payloadValue(base, kind: kind)
        }
        guard let rawPayload, !(rawPayload is NSNull),
              let dict = rawPayload as? [String: Any] else {
            return .failure(CADDrawingServiceError(
                code: "missing_manufacturing_payload",
                message: "This kind needs a \(payloadKey) object."))
        }
        func rejectUnknown(_ allowed: Set<String>) -> CADDrawingServiceError? {
            let unknown = Set(dict.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                return CADDrawingServiceError(
                    code: "unknown_manufacturing_field",
                    message: "Unknown \(payloadKey) field(s): \(unknown.sorted().joined(separator: ", ")).")
            }
            return nil
        }
        switch kind {
        case .datumFeature:
            if let error = rejectUnknown(["letter", "leaderTarget"]) { return .failure(error) }
            guard let letterRaw = dict["letter"] as? String,
                  let letter = CADDrawingManufacturingRules.datumLetter(letterRaw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_datum", message: "datum.letter must be a single A-Z letter."))
            }
            let target: SIMD2<Double>?
            switch optionalPoint(dict["leaderTarget"]) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): target = parsed
            }
            annotation.datum = CADDrawingDatumFeature(letter: letter, leaderTarget: target)
        case .featureControlFrame:
            if let error = rejectUnknown(["characteristic", "toleranceMM", "diameterZone",
                                          "materialCondition", "datumReferences",
                                          "leaderTarget"]) { return .failure(error) }
            guard let characteristicRaw = dict["characteristic"] as? String,
                  let characteristic = CADDrawingGDTSymbol(rawValue: characteristicRaw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_gdt_symbol", message: "Unknown geometric characteristic."))
            }
            guard let tolerance = doubleValue(dict["toleranceMM"]), tolerance.isFinite,
                  tolerance > 0, tolerance <= 1000 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_gdt_tolerance",
                    message: "featureControlFrame.toleranceMM must be in (0, 1000]."))
            }
            var condition: CADDrawingMaterialCondition?
            if let raw = dict["materialCondition"], !(raw is NSNull) {
                guard let name = raw as? String,
                      let parsed = CADDrawingMaterialCondition(rawValue: name) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_material_condition",
                        message: "materialCondition must be maximumMaterial, leastMaterial or regardless."))
                }
                condition = parsed
            }
            var references: [CADDrawingDatumReference] = []
            if let rawReferences = dict["datumReferences"] {
                guard let rows = rawReferences as? [[String: Any]], rows.count <= 3 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_datum_references",
                        message: "datumReferences must be an array of at most three references."))
                }
                for row in rows {
                    let unknown = Set(row.keys).subtracting(["letter", "modifier"])
                    guard unknown.isEmpty else {
                        return .failure(CADDrawingServiceError(
                            code: "unknown_manufacturing_field",
                            message: "Unknown datum reference field."))
                    }
                    guard let letterRaw = row["letter"] as? String,
                          let letter = CADDrawingManufacturingRules.datumLetter(letterRaw) else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_datum_references",
                            message: "Each datum reference needs a single A-Z letter."))
                    }
                    var modifier: CADDrawingMaterialCondition?
                    if let raw = row["modifier"], !(raw is NSNull) {
                        guard let name = raw as? String,
                              let parsed = CADDrawingMaterialCondition(rawValue: name) else {
                            return .failure(CADDrawingServiceError(
                                code: "bad_material_condition",
                                message: "A datum modifier must be maximumMaterial, leastMaterial or regardless."))
                        }
                        if parsed != .regardless { modifier = parsed }
                    }
                    references.append(CADDrawingDatumReference(letter: letter,
                                                               modifier: modifier))
                }
            }
            let target: SIMD2<Double>?
            switch optionalPoint(dict["leaderTarget"]) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): target = parsed
            }
            annotation.featureControlFrame = CADDrawingFeatureControlFrame(
                characteristic: characteristic, toleranceMM: tolerance,
                diameterZone: boolValue(dict["diameterZone"]) ?? false,
                materialCondition: condition, datumReferences: references,
                leaderTarget: target)
        case .surfaceFinish:
            if let error = rejectUnknown(["raMicrometres", "machiningMethod",
                                          "allAround"]) { return .failure(error) }
            guard let ra = doubleValue(dict["raMicrometres"]), ra.isFinite,
                  ra > 0, ra <= 1000 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_surface_finish",
                    message: "surfaceFinish.raMicrometres must be in (0, 1000]."))
            }
            var method: String?
            if let raw = dict["machiningMethod"], !(raw is NSNull) {
                guard let value = raw as? String,
                      let trimmed = CADDrawingManufacturingRules.trimmed(value, maxLength: 40) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_surface_finish",
                        message: "machiningMethod must be 1…40 characters."))
                }
                method = trimmed
            }
            annotation.surfaceFinish = CADDrawingSurfaceFinish(
                raMicrometres: ra, machiningMethod: method,
                allAround: boolValue(dict["allAround"]) ?? false)
        case .weld:
            if let error = rejectUnknown(["type", "sizeMM", "lengthMM", "pitchMM",
                                          "allAround", "fieldWeld", "tailNote",
                                          "leaderTarget"]) { return .failure(error) }
            guard let typeRaw = dict["type"] as? String,
                  let type = CADDrawingWeldType(rawValue: typeRaw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_weld", message: "Unknown weld type."))
            }
            guard let size = doubleValue(dict["sizeMM"]), size.isFinite,
                  size > 0, size <= 1000 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_weld", message: "weld.sizeMM must be in (0, 1000]."))
            }
            var length: Double?
            if let raw = dict["lengthMM"], !(raw is NSNull) {
                guard let value = doubleValue(raw), value.isFinite,
                      value > 0, value <= 100_000 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_weld", message: "weld.lengthMM must be positive and finite."))
                }
                length = value
            }
            var pitch: Double?
            if let raw = dict["pitchMM"], !(raw is NSNull) {
                guard let value = doubleValue(raw), value.isFinite,
                      value > 0, value <= 100_000 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_weld", message: "weld.pitchMM must be positive and finite."))
                }
                pitch = value
            }
            var tail: String?
            if let raw = dict["tailNote"], !(raw is NSNull) {
                guard let value = raw as? String,
                      let trimmed = CADDrawingManufacturingRules.trimmed(value, maxLength: 80) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_weld", message: "tailNote must be 1…80 characters."))
                }
                tail = trimmed
            }
            let target: SIMD2<Double>?
            switch optionalPoint(dict["leaderTarget"]) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): target = parsed
            }
            annotation.weld = CADDrawingWeld(
                type: type, sizeMM: size, lengthMM: length, pitchMM: pitch,
                allAround: boolValue(dict["allAround"]) ?? false,
                fieldWeld: boolValue(dict["fieldWeld"]) ?? false,
                tailNote: tail, leaderTarget: target)
        case .threadCallout:
            if let error = rejectUnknown(["designation", "pitchMM", "threadClass",
                                          "handedness", "through", "depthMM",
                                          "leaderTarget"]) { return .failure(error) }
            guard let designationRaw = dict["designation"] as? String,
                  let parsedDesignation = CADDrawingManufacturingRules
                    .parseThreadDesignation(designationRaw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_thread",
                    message: "designation must be an ISO metric designation such as M6."))
            }
            var pitch = parsedDesignation.pitchMM
            if let raw = dict["pitchMM"], !(raw is NSNull) {
                guard let value = doubleValue(raw) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_thread", message: "thread.pitchMM must be a number."))
                }
                pitch = value
            }
            if pitch == nil {
                pitch = CADDrawingManufacturingRules.coarseMetricPitch(
                    nominalMM: parsedDesignation.nominalMM)
            }
            guard let resolvedPitch = pitch, resolvedPitch.isFinite,
                  resolvedPitch > 0, resolvedPitch <= 6 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_thread", message: "thread.pitchMM must be in (0, 6]."))
            }
            let threadClass = (dict["threadClass"] as? String) ?? "6H"
            guard CADDrawingManufacturingRules.threadClass(threadClass) != nil else {
                return .failure(CADDrawingServiceError(
                    code: "bad_thread", message: "thread.threadClass must look like 6H or 6g."))
            }
            let handedness: CADDrawingThreadHandedness
            if let raw = dict["handedness"], !(raw is NSNull) {
                guard let name = raw as? String,
                      let parsed = CADDrawingThreadHandedness(rawValue: name) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_thread",
                        message: "handedness must be rightHand or leftHand."))
                }
                handedness = parsed
            } else {
                handedness = .rightHand
            }
            let through = boolValue(dict["through"]) ?? true
            var depth: Double?
            if let raw = dict["depthMM"], !(raw is NSNull) {
                guard let value = doubleValue(raw), value.isFinite,
                      value > 0, value <= 1000 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_thread", message: "thread.depthMM must be in (0, 1000]."))
                }
                depth = value
            }
            if !through && depth == nil {
                return .failure(CADDrawingServiceError(
                    code: "bad_thread", message: "A blind thread needs depthMM."))
            }
            let target: SIMD2<Double>?
            switch optionalPoint(dict["leaderTarget"]) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): target = parsed
            }
            annotation.thread = CADDrawingThreadCallout(
                designation: parsedDesignation.canonical, pitchMM: resolvedPitch,
                threadClass: threadClass, handedness: handedness,
                through: through, depthMM: depth, leaderTarget: target)
        case .counterboreCallout:
            if let error = rejectUnknown(["leaderTarget"]) { return .failure(error) }
            let target: SIMD2<Double>?
            switch optionalPoint(dict["leaderTarget"]) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): target = parsed
            }
            annotation.counterbore = CADDrawingCounterboreCallout(leaderTarget: target)
        }
        let issues = CADDrawingManufacturingRules.validate(annotation)
        guard issues.isEmpty else {
            return .failure(CADDrawingServiceError(
                code: "invalid_manufacturing_annotation",
                message: issues.joined(separator: " ")))
        }
        if kind == .threadCallout, let thread = annotation.thread {
            guard let feature else {
                return .failure(CADDrawingServiceError(
                    code: "missing_hole_source",
                    message: "A thread callout requires a linked mechanical hole."))
            }
            let hole: ManufacturingHoleMetadata
            switch holeMetadata(feature) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): hole = parsed
            }
            let sourceIssues = CADDrawingManufacturingRules.validateThread(
                thread, kind: nil, value: nil,
                pilotDiameterMM: hole.pilotDiameterMM,
                sourceThrough: hole.through,
                sourceDepthMM: hole.holeDepthMM)
            guard sourceIssues.isEmpty else {
                return .failure(CADDrawingServiceError(
                    code: "thread_source_mismatch",
                    message: sourceIssues.joined(separator: " ")))
            }
        }
        if kind == .counterboreCallout {
            guard let feature else {
                return .failure(CADDrawingServiceError(
                    code: "missing_hole_source",
                    message: "A counterbore callout requires a linked mechanical hole."))
            }
            let hole: ManufacturingHoleMetadata
            switch holeMetadata(feature) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): hole = parsed
            }
            guard hole.spec.kind == .counterbore,
                  hole.counterboreDiameterMM != nil,
                  hole.counterboreDepthMM != nil else {
                return .failure(CADDrawingServiceError(
                    code: "not_a_counterbore",
                    message: "The linked mechanical hole is not a counterbore."))
            }
        }
        return .success(annotation)
    }

    private func payloadValue(_ annotation: CADDrawingManufacturingAnnotation?,
                              kind: CADDrawingManufacturingKind) -> Any? {
        guard let annotation else { return nil }
        switch kind {
        case .datumFeature: return annotation.datum.flatMap { jsonObject($0) }
        case .featureControlFrame: return annotation.featureControlFrame.flatMap { jsonObject($0) }
        case .surfaceFinish: return annotation.surfaceFinish.flatMap { jsonObject($0) }
        case .weld: return annotation.weld.flatMap { jsonObject($0) }
        case .threadCallout: return annotation.thread.flatMap { jsonObject($0) }
        case .counterboreCallout: return annotation.counterbore.flatMap { jsonObject($0) }
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func optionalPoint(_ raw: Any?)
        -> Result<SIMD2<Double>?, CADDrawingServiceError> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        guard let point = point2(raw) else {
            return .failure(CADDrawingServiceError(
                code: "bad_leader_target",
                message: "leaderTarget must be a finite [x,y] view point."))
        }
        return .success(point)
    }

    private func holeMetadata(_ feature: CADDrawingFeatureReference)
        -> Result<ManufacturingHoleMetadata, CADDrawingServiceError> {
        guard let featureID = feature.featureID,
              let node = document.session.document.features.node(
                FeatureID(raw: featureID)) else {
            return .failure(CADDrawingServiceError(
                code: "missing_hole_feature",
                message: "The linked feature no longer exists; the callout is dangling."))
        }
        guard !node.suppressed else {
            return .failure(CADDrawingServiceError(
                code: "suppressed_hole_feature",
                message: "The linked hole feature is suppressed; the callout is dangling."))
        }
        guard case let .hole(target, profile, _, spec) = node.kind else {
            return .failure(CADDrawingServiceError(
                code: "not_a_hole_feature",
                message: "The linked feature is not a mechanical hole; the callout is dangling."))
        }
        guard let source = body(for: feature.bodyID) else {
            return .failure(CADDrawingServiceError(
                code: "missing_hole_body",
                message: "The linked hole's source body no longer exists."))
        }
        guard Self.featureNode(node, writesBody: target.bodyID)
                || Self.featureNode(node, writesBody: source.id) else {
            return .failure(CADDrawingServiceError(
                code: "hole_source_mismatch",
                message: "The linked feature no longer owns this body; the callout is dangling."))
        }
        guard let sketch = document.session.document.sketches.first(where: {
            $0.id == profile.sketchID
        }) else {
            return .failure(CADDrawingServiceError(
                code: "missing_hole_sketch",
                message: "The linked hole's authoring sketch no longer exists."))
        }
        let pilotDiameter = HoleKit.circle(in: sketch, matching: profile).map { $0.radius * 2 }
        if let issue = HoleKit.validationIssue(spec, pilotDiameter: pilotDiameter) {
            return .failure(CADDrawingServiceError(
                code: "invalid_hole_feature",
                message: "The linked mechanical hole is invalid: \(issue)"))
        }
        let through = spec.kind == .throughAll || spec.kind == .counterbore
            || spec.kind == .countersink
        return .success(ManufacturingHoleMetadata(
            spec: spec,
            pilotDiameterMM: pilotDiameter,
            through: through,
            holeDepthMM: spec.kind == .blind ? spec.depth?.value : nil,
            counterboreDiameterMM: spec.counterboreDiameter?.value,
            counterboreDepthMM: spec.counterboreDepth?.value,
            countersinkDiameterMM: spec.countersinkDiameter?.value,
            countersinkAngleDegrees: spec.countersinkAngle?.value))
    }

    // MARK: - Text annotations

    private func addAnnotationAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard page.annotations.count < 128 else {
            return fail("too_many_annotations", "A page is bounded to 128 text annotations.")
        }
        let requestedViewID = uuidValue(args["viewID"]) ?? uuidValue(args["viewId"])
        if page.isMultiViewSheet && requestedViewID == nil {
            return fail("view_required",
                        "A multi-view sheet needs viewID so the annotation belongs to one view.")
        }
        let view: CADDrawingSheetView
        if let requestedViewID {
            guard let found = page.effectiveSheetViews.first(where: { $0.id == requestedViewID }) else {
                return fail("unknown_view", "viewID does not reference a view on this page.")
            }
            view = found
        } else {
            view = page.effectiveSheetViews[0]
        }
        guard let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 500 else {
            return fail("bad_text", "text must be a non-empty string of at most 500 characters.")
        }
        guard let rawPosition = args["position"], let position = point2(rawPosition) else {
            return fail("bad_position", "position must be a finite [x,y] drawing point.")
        }
        var height = 3.5
        if let raw = args["heightMM"] {
            guard let value = doubleValue(raw), value.isFinite, value >= 0.5, value <= 50 else {
                return fail("bad_height", "heightMM must be a finite number in [0.5, 50].")
            }
            height = value
        }
        var binding: CADDrawingBinding?
        if let instanceID = uuidValue(args["instanceID"]) {
            guard let instance = loadAssemblyValue()?.instance(instanceID),
                  let source = body(for: effectiveBodyID(instance)) else {
                return fail("unknown_instance", "instanceID must reference a live assembly instance.")
            }
            guard let plane = plane(for: page, view: view),
                  let world = instanceWorldTransform(instance: instance, source: source, page: page),
                  let local = bodyLocalPointFromDrawing(position, plane: plane,
                                                       scale: view.scale,
                                                       world: world, source: source) else {
                return fail("bad_position", "The annotation position could not be bound to the part.")
            }
            binding = CADDrawingBinding(instanceID: instance.id, bodyID: source.id.raw,
                                        modelPoints: [local],
                                        sourceRevision: source.meshRevision)
        }
        let annotation = CADDrawingTextAnnotation(
            id: UUID(), text: text, position: position,
            heightMM: height, binding: binding, viewID: requestedViewID)
        page.annotations.append(annotation)
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "annotation": annotationRow(annotation, page: page,
                                            projection: projectPage(page))]
    }

    private func updateAnnotationAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let annotationID = uuidValue(args["annotationID"]),
              let annotationIndex = page.annotations.firstIndex(where: { $0.id == annotationID }) else {
            return fail("unknown_annotation", "No text annotation with that id on this page.")
        }
        var annotation = page.annotations[annotationIndex]
        if let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !text.isEmpty, text.count <= 500 else {
                return fail("bad_text", "text must be a non-empty string of at most 500 characters.")
            }
            annotation.text = text
        }
        if let raw = args["position"] {
            guard let parsed = point2(raw) else {
                return fail("bad_position", "position must be a finite [x,y] drawing point.")
            }
            annotation.position = parsed
            let view = annotation.viewID.flatMap { id in
                page.effectiveSheetViews.first(where: { $0.id == id })
            } ?? page.effectiveSheetViews[0]
            if let binding = annotation.binding,
               let instance = loadAssemblyValue()?.instance(binding.instanceID ?? UUID()),
               let source = binding.bodyID.flatMap({ body(for: $0) })
                    ?? body(for: effectiveBodyID(instance)),
               let plane = plane(for: page, view: view),
               let world = instanceWorldTransform(instance: instance, source: source, page: page),
               let local = bodyLocalPointFromDrawing(parsed, plane: plane,
                                                     scale: view.scale,
                                                     world: world, source: source) {
                annotation.binding = CADDrawingBinding(
                    instanceID: instance.id, bodyID: source.id.raw,
                    modelPoints: [local],
                    sourceRevision: source.meshRevision)
            }
        }
        if let raw = args["heightMM"] {
            guard let value = doubleValue(raw), value.isFinite, value >= 0.5, value <= 50 else {
                return fail("bad_height", "heightMM must be a finite number in [0.5, 50].")
            }
            annotation.heightMM = value
        }
        page.annotations[annotationIndex] = annotation
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "annotation": annotationRow(annotation, page: page,
                                            projection: projectPage(page))]
    }

    private func removeAnnotationAction(_ args: [String: Any]) -> [String: Any] {
        let set: CADDrawingSet
        switch loadSet() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): set = loaded
        }
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let index = set.pages.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_page", "No drawing page with that id.")
        }
        var page = set.pages[index]
        guard let annotationID = uuidValue(args["annotationID"]),
              page.annotations.contains(where: { $0.id == annotationID }) else {
            return fail("unknown_annotation", "No text annotation with that id on this page.")
        }
        page.annotations.removeAll { $0.id == annotationID }
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true, "removedAnnotation": annotationID.uuidString,
                "annotationCount": page.annotations.count]
    }

    // MARK: - Page construction / validation

    private func buildPage(args: [String: Any],
                           existing: CADDrawingPage?)
        -> Result<CADDrawingPage, CADDrawingServiceError> {
        let kind: CADDrawingViewKind
        if let raw = args["kind"] {
            guard let name = raw as? String, let parsed = CADDrawingViewKind(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_kind",
                    message: "kind must be front, top, side, iso, section, detail or exploded."))
            }
            kind = parsed
        } else if let existing {
            kind = existing.kind
        } else {
            return .failure(CADDrawingServiceError(
                code: "missing_kind", message: "addPage needs a kind."))
        }

        // Source bodies: every id must resolve, at most 12 per page.
        var sourceBodyIDs = existing?.sourceBodyIDs ?? []
        if let raw = args["bodyIDs"] ?? args["sourceBodyIDs"] {
            guard let strings = raw as? [String] else {
                return .failure(CADDrawingServiceError(
                    code: "bad_body_ids",
                    message: "bodyIDs must be an array of body UUID strings."))
            }
            var ids: [UUID] = []
            ids.reserveCapacity(strings.count)
            for string in strings {
                guard let id = UUID(uuidString: string), body(for: id) != nil else {
                    return .failure(CADDrawingServiceError(
                        code: "unknown_body",
                        message: "bodyIDs must all reference live document bodies."))
                }
                ids.append(id)
            }
            guard ids.count <= Self.maxSourceBodies else {
                return .failure(CADDrawingServiceError(
                    code: "too_many_bodies",
                    message: "A page is bounded to \(Self.maxSourceBodies) source bodies."))
            }
            guard Set(ids).count == ids.count else {
                return .failure(CADDrawingServiceError(
                    code: "duplicate_body", message: "bodyIDs must not repeat."))
            }
            sourceBodyIDs = ids
        }

        var scale = existing?.scale ?? 1
        if let raw = args["scale"] {
            guard let value = doubleValue(raw), value.isFinite,
                  value > 0, value <= 1000 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_scale",
                    message: "scale must be a finite number in (0, 1000]."))
            }
            scale = value
        }

        var paper = existing?.paper ?? .a3
        if let raw = args["paper"] {
            guard let name = raw as? String, let parsed = CADPaperSize(rawValue: name) else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_paper",
                    message: "paper must be a4, a3, a2, a1, a0, letter, tabloid or custom."))
            }
            paper = parsed
        }

        var customWidth = existing?.customWidthMM
        var customHeight = existing?.customHeightMM
        if let raw = args["customWidthMM"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_paper_size",
                    message: "customWidthMM must be a finite, positive number."))
            }
            customWidth = value
        }
        if let raw = args["customHeightMM"] {
            guard let value = doubleValue(raw), value.isFinite, value > 0 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_paper_size",
                    message: "customHeightMM must be a finite, positive number."))
            }
            customHeight = value
        }

        // Detail window (center in `sectionOrigin`, size in `sectionNormal`;
        // see the header note) is handled with the section plane below.
        if paper == .custom {
            guard let width = customWidth, let height = customHeight,
                  width > 0, height > 0 else {
                return .failure(CADDrawingServiceError(
                    code: "missing_custom_paper",
                    message: "custom paper needs customWidthMM and customHeightMM."))
            }
        }

        var viewNormal: SIMD3<Double>
        if let existing, existing.kind == kind {
            viewNormal = existing.viewNormal
        } else {
            viewNormal = defaultViewNormal(for: kind)
        }
        if let raw = args["viewNormal"] {
            guard let vector = vector3(raw), simd_length(vector) > 1e-9 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_view_normal",
                    message: "viewNormal must be a non-zero finite [x,y,z]."))
            }
            viewNormal = simd_normalize(vector)
        }
        var viewUp = existing?.viewUp ?? SIMD3<Double>(0, 1, 0)
        if let raw = args["viewUp"] {
            guard let vector = vector3(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_view_up",
                    message: "viewUp must be a finite [x,y,z]."))
            }
            viewUp = simd_length(vector) > 1e-9 ? simd_normalize(vector)
                                              : SIMD3<Double>(0, 1, 0)
        }

        // Section plane / detail window. Neither is inherited across a kind
        // change: converting a detail page to a front view must not leave the
        // window behind as a bogus cutting plane. The detail window has its
        // OWN typed fields (detailOrigin/detailSizeMM), never aliased into the
        // section plane.
        var sectionOrigin: SIMD3<Double>? =
            existing?.kind == .section ? existing?.sectionOrigin : nil
        var sectionNormal: SIMD3<Double>? =
            existing?.kind == .section ? existing?.sectionNormal : nil
        var detailOrigin: SIMD3<Double>? =
            existing?.kind == .detail ? existing?.detailOrigin : nil
        var detailSizeMM: SIMD2<Double>? =
            existing?.kind == .detail ? existing?.detailSizeMM : nil
        if let raw = args["sectionOrigin"] {
            guard let vector = vector3(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_section_origin",
                    message: "sectionOrigin must be a finite [x,y,z]."))
            }
            sectionOrigin = vector
        }
        if let raw = args["sectionNormal"] {
            guard let vector = vector3(raw), simd_length(vector) > 1e-9 else {
                return .failure(CADDrawingServiceError(
                    code: "bad_section_normal",
                    message: "sectionNormal must be a non-zero finite [x,y,z]."))
            }
            sectionNormal = simd_normalize(vector)
        }
        if kind == .section {
            guard let normal = sectionNormal, sectionOrigin != nil else {
                return .failure(CADDrawingServiceError(
                    code: "missing_section_plane",
                    message: "section pages need sectionOrigin and sectionNormal."))
            }
            if args["viewNormal"] == nil { viewNormal = normal }
        }
        if kind == .detail {
            if let raw = args["detailOrigin"] {
                guard let vector = vector3(raw) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_detail_origin",
                        message: "detailOrigin must be a finite [x,y,z]."))
                }
                detailOrigin = vector
            }
            if let raw = args["detailSizeMM"] {
                guard let size = sizeValue(raw), size.width > 0, size.height > 0 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_detail_size",
                        message: "detailSizeMM must be a positive number or [width, height]."))
                }
                detailSizeMM = SIMD2(size.width, size.height)
            }
            guard let size = detailSizeMM, size.x > 0, size.y > 0 else {
                return .failure(CADDrawingServiceError(
                    code: "missing_detail_size",
                    message: "detail pages need detailSizeMM (mm, number or [width, height])."))
            }
            guard detailOrigin != nil else {
                return .failure(CADDrawingServiceError(
                    code: "missing_detail_origin",
                    message: "detail pages need detailOrigin."))
            }
        }

        var title = existing?.title ?? ""
        if let raw = args["title"] {
            guard let value = raw as? String else {
                return .failure(CADDrawingServiceError(
                    code: "bad_title", message: "title must be a string."))
            }
            title = value
        }
        var partNumbers = existing?.partNumbers ?? []
        if let raw = args["partNumbers"] {
            guard let values = raw as? [String] else {
                return .failure(CADDrawingServiceError(
                    code: "bad_part_numbers",
                    message: "partNumbers must be an array of strings."))
            }
            partNumbers = values
        }
        var showDimensions = existing?.showDimensions ?? false
        if let raw = args["showDimensions"] {
            guard let value = boolValue(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_flag", message: "showDimensions must be a boolean."))
            }
            showDimensions = value
        }
        var showCenterlines = existing?.showCenterlines ?? false
        if let raw = args["showCenterlines"] {
            guard let value = boolValue(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_flag", message: "showCenterlines must be a boolean."))
            }
            showCenterlines = value
        }
        var name = existing?.name ?? kind.title
        if let raw = args["name"] {
            guard let value = raw as? String, !value.isEmpty else {
                return .failure(CADDrawingServiceError(
                    code: "bad_name", message: "name must be a non-empty string."))
            }
            name = value
        }

        // Assembly-aware projection. A page only switches to placed instances
        // when it explicitly asks (or is an exploded view); ordinary pages
        // keep projecting raw body transforms exactly as before.
        var assemblyMode = existing?.assemblyMode ?? false
        if let raw = args["assemblyMode"] {
            guard let value = boolValue(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_flag", message: "assemblyMode must be a boolean."))
            }
            assemblyMode = value
        }
        if kind == .exploded { assemblyMode = true }
        var explodedViewID = existing?.explodedViewID
        if args.keys.contains("explodedViewID") {
            let raw = args["explodedViewID"]
            if raw == nil || raw is NSNull {
                explodedViewID = nil
            } else {
                guard let id = uuidValue(raw) else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_view_id", message: "explodedViewID must be an exploded-view UUID."))
                }
                guard let assembly = loadAssemblyValue(),
                      assembly.explodedView(id) != nil else {
                    return .failure(CADDrawingServiceError(
                        code: "unknown_exploded_view",
                        message: "explodedViewID does not reference a stored exploded view."))
                }
                explodedViewID = id
            }
        }
        if explodedViewID != nil { assemblyMode = true }
        var explodedViewName = existing?.explodedViewName
        if let id = explodedViewID,
           let view = loadAssemblyValue()?.explodedView(id) {
            explodedViewName = view.name
        } else if args.keys.contains("explodedViewName") {
            explodedViewName = args["explodedViewName"] as? String
        }

        var showBOM = existing?.showBOM ?? false
        if let raw = args["showBOM"] {
            guard let value = boolValue(raw) else {
                return .failure(CADDrawingServiceError(
                    code: "bad_flag", message: "showBOM must be a boolean."))
            }
            showBOM = value
        }

        var page = CADDrawingPage(
            id: existing?.id ?? UUID(),
            name: name,
            kind: kind,
            scale: scale,
            paper: paper,
            title: title,
            partNumbers: partNumbers,
            sourceBodyIDs: sourceBodyIDs,
            viewNormal: viewNormal,
            viewUp: viewUp,
            sectionOrigin: sectionOrigin,
            sectionNormal: sectionNormal,
            detailOrigin: detailOrigin,
            detailSizeMM: detailSizeMM,
            modelRevision: nil,
            showCenterlines: showCenterlines,
            showDimensions: showDimensions,
            assemblyMode: assemblyMode,
            explodedViewID: explodedViewID,
            explodedViewName: explodedViewName,
            showBOM: showBOM,
            bom: existing?.bom,
            balloons: existing?.balloons ?? [],
            manualDimensions: existing?.manualDimensions ?? [],
            annotations: existing?.annotations ?? [],
            sheetViews: existing?.sheetViews)
        page.customWidthMM = customWidth
        page.customHeightMM = customHeight
        // New non-additive records are edited by their own actions; a page
        // update preserves them rather than dropping unknown data.
        page.manufacturingAnnotations = existing?.manufacturingAnnotations ?? []
        page.revisionRows = existing?.revisionRows ?? []
        page.sheetTemplate = existing?.sheetTemplate
        page.units = existing?.units
        page.precision = existing?.precision
        page.titleBlock = existing?.titleBlock

        if let raw = args["units"] {
            if raw is NSNull {
                page.units = nil
            } else if let name = raw as? String, let unit = CADDrawingUnit(rawValue: name) {
                page.units = unit
            } else {
                return .failure(CADDrawingServiceError(
                    code: "unknown_unit",
                    message: "units must be millimetre, centimetre or inch."))
            }
        }
        if let raw = args["precision"] {
            if raw is NSNull {
                page.precision = nil
            } else if let value = intValue(raw), (0...4).contains(value) {
                page.precision = value
            } else {
                return .failure(CADDrawingServiceError(
                    code: "bad_precision",
                    message: "precision must be an integer from 0 to 4."))
            }
        }
        if let raw = args["revisionRows"] {
            if raw is NSNull {
                page.revisionRows = []
            } else {
                guard let rows = raw as? [[String: Any]] else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_revision_rows",
                        message: "revisionRows must be an array of row objects."))
                }
                guard rows.count <= CADDrawingTemplateRules.maximumRevisionRows else {
                    return .failure(CADDrawingServiceError(
                        code: "too_many_revision_rows",
                        message: "A sheet supports at most \(CADDrawingTemplateRules.maximumRevisionRows) revision rows."))
                }
                var parsed: [CADDrawingRevisionRow] = []
                for row in rows {
                    let unknown = Set(row.keys).subtracting(["id", "revision", "date",
                                                             "description", "approvedBy"])
                    guard unknown.isEmpty else {
                        return .failure(CADDrawingServiceError(
                            code: "unknown_revision_row_field",
                            message: "Unknown revision row field(s): "
                                + unknown.sorted().joined(separator: ", ") + "."))
                    }
                    guard let revision = row["revision"] as? String,
                          let description = row["description"] as? String else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_revision_rows",
                            message: "Each revision row needs revision and description strings."))
                    }
                    guard row["date"] == nil || row["date"] is String || row["date"] is NSNull,
                          row["approvedBy"] == nil || row["approvedBy"] is String
                            || row["approvedBy"] is NSNull else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_revision_rows",
                            message: "date/approvedBy must be strings or null."))
                    }
                    let date = row["date"] as? String ?? ""
                    let approvedBy = row["approvedBy"] as? String
                    guard revision.count <= 16, date.count <= 24,
                          description.count <= 80, (approvedBy?.count ?? 0) <= 40 else {
                        return .failure(CADDrawingServiceError(
                            code: "bad_revision_rows",
                            message: "A revision row field is longer than its bound."))
                    }
                    parsed.append(CADDrawingRevisionRow(
                        id: uuidValue(row["id"]) ?? UUID(),
                        revision: revision,
                        date: date,
                        description: description,
                        approvedBy: approvedBy))
                }
                page.revisionRows = parsed
            }
        }
        if let raw = args["titleBlock"] {
            if raw is NSNull {
                page.titleBlock = nil
            } else if let object = raw as? [String: Any],
                      let company = object["company"] as? String,
                      let drawingNumber = object["drawingNumber"] as? String {
                let unknown = Set(object.keys).subtracting(["company", "drawingNumber"])
                guard unknown.isEmpty else {
                    return .failure(CADDrawingServiceError(
                        code: "unknown_title_block_field",
                        message: "Unknown titleBlock field(s): "
                            + unknown.sorted().joined(separator: ", ") + "."))
                }
                guard company.count <= 80, drawingNumber.count <= 60 else {
                    return .failure(CADDrawingServiceError(
                        code: "bad_title_block",
                        message: "The company name is bounded to 80 and the drawing number to 60 characters."))
                }
                page.titleBlock = CADDrawingTitleBlock(company: company,
                                                       drawingNumber: drawingNumber)
            } else {
                return .failure(CADDrawingServiceError(
                    code: "bad_title_block",
                    message: "titleBlock must be {company, drawingNumber} strings."))
            }
        }
        return .success(page)
    }

    private func defaultViewNormal(for kind: CADDrawingViewKind) -> SIMD3<Double> {
        switch kind {
        case .front: return SIMD3(0, -1, 0)
        case .top: return SIMD3(0, 0, 1)
        case .side: return SIMD3(1, 0, 0)
        case .iso: return SIMD3(1, -1, 1)
        case .exploded: return SIMD3(1, -1, 1)
        case .section: return SIMD3(0, 0, 1)
        case .detail: return SIMD3(0, -1, 0)
        }
    }

    // MARK: - Projection

    /// Resolved geometry inputs for one page. In assembly mode these are the
    /// actual placed instances (base placement + optional exploded offset),
    /// never the raw source-body transforms; ordinary pages keep the previous
    /// body-id behaviour.
    private func projectionSources(for page: CADDrawingPage,
                                   sourceBodyIDs: [UUID]? = nil) -> ResolvedProjectionSources {
        var result = ResolvedProjectionSources()
        let assemblyAware = page.assemblyMode || page.kind == .exploded
            || page.explodedViewID != nil
        let filterIDs = sourceBodyIDs ?? page.sourceBodyIDs
        guard assemblyAware else {
            for id in filterIDs {
                if let body = body(for: id) {
                    result.sources.append(ProjectionSource(instanceID: nil,
                                                           name: body.name,
                                                           body: body))
                } else {
                    result.missingBodies.append(id)
                }
            }
            if !result.missingBodies.isEmpty {
                result.notes.append("\(result.missingBodies.count) source body id(s) no longer resolve; "
                                    + "their geometry is omitted.")
            }
            return result
        }

        guard let data = document.session.document.assemblyData, !data.isEmpty else {
            result.notes.append("This page projects assembly instances, but the document has no assembly data.")
            return result
        }
        let assembly: CADAssembly
        do {
            assembly = try CADAssembly.decode(from: data)
        } catch {
            result.notes.append("The stored assembly JSON could not be read; the page projected nothing.")
            return result
        }
        let view = page.explodedViewID.flatMap { assembly.explodedView($0) }
        if let id = page.explodedViewID, view == nil {
            result.notes.append("Exploded view \(page.explodedViewName ?? id.uuidString) no longer exists; "
                                + "the base placements were projected for display, but vector output is "
                                + "blocked until a live view is selected.")
        }
        result.explodedViewID = view?.id
        result.explodedViewName = view?.name ?? page.explodedViewName

        let filter = Set(filterIDs)
        let maxInstances = 64
        var occurrences = assembly.occurrences(viewID: view?.id, includeHidden: false)
            .filter { $0.isDrawablePart }
        if !filter.isEmpty {
            occurrences = occurrences.filter { occurrence in
                occurrence.effectiveBodyID.map(filter.contains) ?? false
            }
            let used = Set(occurrences.compactMap { $0.effectiveBodyID })
            let unused = filter.subtracting(used)
            if !unused.isEmpty {
                result.notes.append("\(unused.count) source body id(s) have no visible assembly instance.")
            }
        }
        if occurrences.count > maxInstances {
            occurrences = Array(occurrences.prefix(maxInstances))
            result.notes.append("Projection is bounded to \(maxInstances) assembly instances; "
                                + "later instances were omitted.")
        }
        if occurrences.isEmpty {
            result.notes.append("No visible assembly instance matches this page's source bodies.")
        }

        for occurrence in occurrences {
            guard let sourceID = occurrence.effectiveBodyID else { continue }
            let instance = occurrence.instance
            guard let source = body(for: sourceID) else {
                result.missingBodies.append(sourceID)
                result.missingInstances.append(instance.id)
                continue
            }
            let placement = occurrence.explodedWorldTransform ?? occurrence.worldTransform
            guard placement.isPlaceable else {
                result.missingInstances.append(instance.id)
                result.notes.append("Instance \(instance.name) has a non-placeable transform and was omitted.")
                continue
            }
            let world = placement.placement3D().composed(onto: source.transform)
            var placed = Body(id: BodyID(raw: instance.id),
                              name: instance.name,
                              transform: world,
                              render: source.render,
                              edges: source.edges,
                              revision: source.meshRevision)
            // The B-rep is body-local and immutable; carrying it lets exact
            // section/circle work run on the placed transform.
            placed.brep = source.brep
            placed.surfaceBRep = source.surfaceBRep
            result.sources.append(ProjectionSource(instanceID: instance.id,
                                                   name: instance.name,
                                                   body: placed))
        }
        if !result.missingInstances.isEmpty {
            result.notes.append("\(result.missingInstances.count) placed instance(s) no longer resolve a body.")
        }
        return result
    }

    /// Project one page. A legacy page (no `sheetViews`) goes through the
    /// historical single-view path so its payload/coordinates stay identical.
    /// A v4 shared sheet projects every view, solves its alignment layout and
    /// merges the views in sheet coordinates.
    private func projectPage(_ page: CADDrawingPage) -> PageProjection {
        let views = page.effectiveSheetViews
        if page.sheetViews == nil, views.count == 1 {
            return projectSingleView(page: page, view: views[0])
        }
        return projectSheet(page)
    }

    /// Local bounds only, used by auto-layout before any offset is applied.
    private func projectSheetPreview(_ page: CADDrawingPage) -> PageProjection {
        projectSheet(page, applyLayout: false)
    }

    private func projectSheet(_ page: CADDrawingPage,
                              applyLayout: Bool = true) -> PageProjection {
        let views = page.effectiveSheetViews
        var perView: [CADDrawingViewProjection] = []
        perView.reserveCapacity(views.count)
        for view in views {
            let local = projectSingleView(page: page, view: view)
            var item = CADDrawingViewProjection(view: view)
            item.entities = local.entities
            item.instances = local.instances
            item.notes = local.notes
            item.missing = local.missing
            item.missingInstances = local.missingInstances
            item.sectionCoverage = local.sectionCoverage
            item.sectionComplete = local.sectionComplete
            item.localBounds = entityBounds(local.entities)
            item.bounds = item.localBounds
            perView.append(item)
        }
        var issues: [String] = []
        let offsets: [SIMD2<Double>]
        if applyLayout {
            offsets = resolveViewOffsets(views: views, projections: perView, issues: &issues)
        } else {
            offsets = Array(repeating: SIMD2<Double>.zero, count: views.count)
        }
        for index in perView.indices {
            perView[index].offset = offsets[index]
            if offsets[index] != .zero {
                perView[index].entities = perView[index].entities.map {
                    $0.translated(by: offsets[index])
                }
                perView[index].instances = perView[index].instances.map { instance in
                    var copy = instance
                    copy.entities = copy.entities.map { $0.translated(by: offsets[index]) }
                    return copy
                }
            }
            perView[index].bounds = entityBounds(perView[index].entities)
        }

        var result = PageProjection()
        result.views = perView
        result.viewIssues = issues
        var notes: [String] = []
        for item in perView {
            if views.count > 1 {
                notes.append(contentsOf: item.notes.map { "\(item.view.name): \($0)" })
            } else {
                notes.append(contentsOf: item.notes)
            }
            result.entities.append(contentsOf: item.entities)
            result.instances.append(contentsOf: item.instances)
            result.missing.append(contentsOf: item.missing)
            result.missingInstances.append(contentsOf: item.missingInstances)
            result.sectionCoverage.append(contentsOf: item.sectionCoverage)
        }
        result.notes = notes
        result.missing = Array(Set(result.missing))
        result.missingInstances = Array(Set(result.missingInstances))
        result.sectionIncomplete = perView.contains { !$0.sectionComplete }
        result.outputBlocked = result.sectionIncomplete
        result.explodedViewID = page.explodedViewID
        result.explodedViewName = page.explodedViewName
        return result
    }

    /// Resolve each view's sheet offset. A free view uses its stored offset.
    /// An aligned view is placed against its reference's LIVE projected
    /// bounds (cross axis centred, gap on the placement axis) and then gains
    /// its stored offset as a nudge. Cycles/invalid references fall back to
    /// the stored offset and are reported, never guessed.
    private func resolveViewOffsets(views: [CADDrawingSheetView],
                                    projections: [CADDrawingViewProjection],
                                    issues: inout [String]) -> [SIMD2<Double>] {
        var resolved: [UUID: SIMD2<Double>] = [:]
        var visiting = Set<UUID>()
        var localIssues: [String] = []
        func offset(for index: Int, depth: Int) -> SIMD2<Double> {
            let view = views[index]
            if let cached = resolved[view.id] { return cached }
            if depth > 8 || visiting.contains(view.id) {
                localIssues.append("View \(view.name): alignment cycle or depth limit; using its offset.")
                return view.offset
            }
            guard view.alignment.placement != .free,
                  let referenceID = view.alignment.referenceViewID,
                  let referenceIndex = views.firstIndex(where: { $0.id == referenceID }),
                  referenceIndex != index else {
                if view.alignment.placement != .free {
                    localIssues.append("View \(view.name): alignment reference is missing; using its offset.")
                }
                resolved[view.id] = view.offset
                return view.offset
            }
            visiting.insert(view.id)
            let referenceOffset = offset(for: referenceIndex, depth: depth + 1)
            visiting.remove(view.id)
            guard let own = projections[index].localBounds,
                  let referenceLocal = projections[referenceIndex].localBounds else {
                resolved[view.id] = view.offset
                return view.offset
            }
            let referenceBounds = (min: referenceLocal.min + referenceOffset,
                                   max: referenceLocal.max + referenceOffset)
            let gap = max(view.alignment.gapMM, 0)
            var base = SIMD2<Double>.zero
            switch view.alignment.placement {
            case .free:
                base = .zero
            case .above:
                base.x = (referenceBounds.min.x + referenceBounds.max.x) / 2
                    - (own.min.x + own.max.x) / 2
                base.y = referenceBounds.max.y + gap - own.min.y
            case .below:
                base.x = (referenceBounds.min.x + referenceBounds.max.x) / 2
                    - (own.min.x + own.max.x) / 2
                base.y = referenceBounds.min.y - gap - own.max.y
            case .left:
                base.x = referenceBounds.min.x - gap - own.max.x
                base.y = (referenceBounds.min.y + referenceBounds.max.y) / 2
                    - (own.min.y + own.max.y) / 2
            case .right:
                base.x = referenceBounds.max.x + gap - own.min.x
                base.y = (referenceBounds.min.y + referenceBounds.max.y) / 2
                    - (own.min.y + own.max.y) / 2
            }
            let value = base + view.offset
            resolved[view.id] = value
            return value
        }
        let result = views.indices.map { offset(for: $0, depth: 0) }
        issues.append(contentsOf: localIssues)
        return result
    }

    /// Project one view in its own local sheet coordinates (no layout offset).
    private func projectSingleView(page: CADDrawingPage,
                                   view: CADDrawingSheetView) -> PageProjection {
        let resolved = projectionSources(for: page, sourceBodyIDs: view.sourceBodyIDs)
        guard view.scale.isFinite, view.scale > 0 else {
            var result = PageProjection()
            result.notes = resolved.notes + ["view scale is invalid; nothing was projected."]
            result.missing = resolved.missingBodies
            result.missingInstances = resolved.missingInstances
            if view.kind == .section {
                result.sectionComplete = false
                result.sectionIncomplete = true
                result.outputBlocked = true
            }
            return result
        }
        var header = PageProjection()
        header.notes = resolved.notes
        header.missing = resolved.missingBodies
        header.missingInstances = resolved.missingInstances
        header.explodedViewID = resolved.explodedViewID
        header.explodedViewName = resolved.explodedViewName
        if view.kind == .section,
           (!resolved.missingBodies.isEmpty || !resolved.missingInstances.isEmpty) {
            header.sectionIncomplete = true
            header.sectionComplete = false
            header.notes.append("The section is INCOMPLETE: one or more sources are missing.")
        }
        guard !resolved.sources.isEmpty else {
            if view.kind == .section {
                header.sectionIncomplete = true
                header.sectionComplete = false
                if header.notes.isEmpty {
                    header.notes.append("The section is INCOMPLETE: no section source resolved.")
                }
            }
            return header
        }
        switch view.kind {
        case .section:
            return projectSection(page: page, view: view, sources: resolved.sources,
                                  header: header)
        case .front, .top, .side, .iso, .exploded:
            return projectView(page: page, view: view, sources: resolved.sources,
                               header: header)
        case .detail:
            return projectDetail(page: page, view: view, sources: resolved.sources,
                                 header: header)
        }
    }

    /// The in-plane frame for one view: `SectionKit.frame(normal:xAxisHint:)`
    /// with the VIEW's normal and up hint, matching section loop coordinates.
    private func plane(for page: CADDrawingPage,
                       view: CADDrawingSheetView) -> SketchPlane? {
        let normal: SIMD3<Double>
        switch view.kind {
        case .section:
            guard let stored = view.sectionNormal, simd_length(stored) > 1e-9 else { return nil }
            normal = simd_normalize(stored)
        default:
            guard simd_length(view.viewNormal) > 1e-9 else { return nil }
            normal = simd_normalize(view.viewNormal)
        }
        let frame = SectionKit.frame(normal: normal, xAxisHint: view.viewUp)
        return SketchPlane(origin: .zero, xAxis: frame.xAxis, yAxis: frame.yAxis)
    }

    private func projectView(page: CADDrawingPage, view: CADDrawingSheetView,
                             sources: [ProjectionSource],
                             header: PageProjection) -> PageProjection {
        guard let plane = plane(for: page, view: view) else {
            var result = header
            result.notes.append("view direction is invalid")
            return result
        }
        var entities: [ProjectedEntity] = []
        var groups: [UUID: [ProjectedEntity]] = [:]
        for source in sources {
            let outline = ProjectionKit.projectSilhouette(body: source.body, onto: plane)
                .map { convert($0, layer: "outline") }
            let edges = ProjectionKit.project(body: source.body, onto: plane)
                .map { convert($0, layer: "edges") }
            let exact = exactCylinderCircles(bodies: [source.body], plane: plane,
                                             normal: plane.normal)
            var projected = dedupe(circularize(outline, exact: exact)
                                    + circularize(edges, exact: exact))
            projected = projected.map { $0.scaled(by: view.scale) }
            entities.append(contentsOf: projected)
            if let id = source.instanceID {
                groups[id, default: []].append(contentsOf: projected)
            }
        }
        return completedProjection(header: header, view: view,
                                   entities: entities, groups: groups,
                                   sources: sources)
    }

    private func projectSection(page: CADDrawingPage, view: CADDrawingSheetView,
                                sources: [ProjectionSource],
                                header: PageProjection) -> PageProjection {
        guard let origin = view.sectionOrigin,
              let storedNormal = view.sectionNormal,
              simd_length(storedNormal) > 1e-9 else {
            var result = header
            result.notes.append("section views need sectionOrigin and sectionNormal")
            result.sectionComplete = false
            result.sectionIncomplete = true
            result.outputBlocked = true
            return result
        }
        let normal = simd_normalize(storedNormal)
        let frame = SectionKit.frame(normal: normal, xAxisHint: view.viewUp)
        var entities: [ProjectedEntity] = []
        var groups: [UUID: [ProjectedEntity]] = [:]
        var coverage: [CADDrawingSectionCoverage] = []
        var incomplete = false
        let assembly = loadAssemblyValue()
        for source in sources {
            let coverageBodyID: UUID
            if let instanceID = source.instanceID,
               let instance = assembly?.instance(instanceID) {
                coverageBodyID = effectiveBodyID(instance)
            } else {
                coverageBodyID = source.body.id.raw
            }
            let item = CADDrawingSectionCoverage(
                bodyID: coverageBodyID,
                instanceID: source.instanceID,
                name: source.name,
                analyticBRep: source.body.brep != nil,
                included: source.body.brep != nil)
            coverage.append(item)
            guard let brep = source.body.brep else {
                incomplete = true
                continue
            }
            // The kernel section runs on the body-local solid: map the world
            // plane in, then the resulting points back out.
            let localOrigin = bodyLocal(origin, source.body.transform)
            let localNormal = normalizeDirection(
                source.body.transform.rotation.inverse.act(normal))
            // A fine chord deflection keeps curved section boundaries (bores,
            // rounds) faithful at drawing scale; the default 0.05 mm visibly
            // underestimates small hole areas.
            let polylines = OCCTKernel.sectionPolylines(brep, origin: localOrigin,
                                                        normal: localNormal,
                                                        deflection: 0.005)
            let worldPieces = polylines.map { piece in
                piece.map { source.body.transform.applying(to: $0) }
            }
            let loops = SectionKit.loops(from: worldPieces, origin: origin,
                                         xAxis: frame.xAxis, yAxis: frame.yAxis)
            var projected: [ProjectedEntity] = []
            for loop in loops where loop.points.count >= 2 {
                projected.append(ProjectedEntity(
                    shape: .polyline(points: loop.points.map { $0 * view.scale },
                                     closed: loop.closed),
                    layer: "section",
                    area: loop.area * view.scale * view.scale))
            }
            entities.append(contentsOf: projected)
            if let id = source.instanceID {
                groups[id, default: []].append(contentsOf: projected)
            }
        }
        var result = completedProjection(header: header, view: view,
                                         entities: entities, groups: groups,
                                         sources: sources)
        result.sectionCoverage = coverage
        result.sectionComplete = !incomplete
        result.sectionIncomplete = incomplete
        result.outputBlocked = incomplete
        if incomplete {
            result.notes.append("\(coverage.filter { !$0.analyticBRep }.count) "
                                + "mesh-only body/bodies have no analytic section; "
                                + "this section is INCOMPLETE and vector output is blocked.")
        }
        return result
    }

    private func projectDetail(page: CADDrawingPage, view: CADDrawingSheetView,
                               sources: [ProjectionSource],
                               header: PageProjection) -> PageProjection {
        var header = header
        guard let plane = plane(for: page, view: view),
              let centerPoint = view.detailOrigin,
              let windowSize = view.detailSizeMM,
              windowSize.x > 0, windowSize.y > 0 else {
            header.notes.append("detail window is missing; projecting the full view.")
            return projectView(page: page, view: view, sources: sources, header: header)
        }
        let width = windowSize.x
        let height = windowSize.y
        let center = plane.toLocal(centerPoint)
        let rect = (min: SIMD2(center.x - width / 2, center.y - height / 2),
                    max: SIMD2(center.x + width / 2, center.y + height / 2))
        var entities: [ProjectedEntity] = []
        var groups: [UUID: [ProjectedEntity]] = [:]
        for source in sources {
            let projected = ProjectionKit.projectSilhouette(body: source.body, onto: plane)
                + ProjectionKit.project(body: source.body, onto: plane)
            var clippedEntities: [ProjectedEntity] = []
            for entity in projected {
                clippedEntities.append(contentsOf: clipped(convert(entity, layer: "detail"),
                                                           to: rect))
            }
            clippedEntities = clippedEntities.map { $0.scaled(by: view.scale) }
            entities.append(contentsOf: clippedEntities)
            if let id = source.instanceID {
                groups[id, default: []].append(contentsOf: clippedEntities)
            }
        }
        return completedProjection(header: header, view: view,
                                   entities: entities, groups: groups,
                                   sources: sources)
    }

    private func completedProjection(header: PageProjection,
                                     view: CADDrawingSheetView,
                                     entities: [ProjectedEntity],
                                     groups: [UUID: [ProjectedEntity]],
                                     sources: [ProjectionSource]) -> PageProjection {
        var result = header
        result.entities = entities
        result.instances = sources.compactMap { source -> ProjectedInstance? in
            guard let id = source.instanceID else { return nil }
            return ProjectedInstance(id: id, name: source.name,
                                     entities: groups[id] ?? [])
        }
        _ = view
        return result
    }

    private func convert(_ entity: SketchEntity, layer: String) -> ProjectedEntity {
        switch entity {
        case let .line(_, a, b):
            return ProjectedEntity(shape: .line(a, b), layer: layer)
        case let .circle(_, center, radius):
            return ProjectedEntity(shape: .circle(center: center, radius: radius), layer: layer)
        case let .arc(_, center, radius, startAngle, endAngle):
            return ProjectedEntity(shape: .arc(center: center, radius: radius,
                                               startAngle: startAngle,
                                               endAngle: endAngle),
                                   layer: layer)
        case let .rect(_, minPoint, maxPoint):
            let points = [minPoint, SIMD2(maxPoint.x, minPoint.y), maxPoint,
                          SIMD2(minPoint.x, maxPoint.y)]
            return ProjectedEntity(shape: .polyline(points: points, closed: true), layer: layer)
        case let .ellipse(_, center, radiusX, radiusY, rotation):
            let points = SketchEntity.ellipsePoints(center: center, radiusX: radiusX,
                                                    radiusY: radiusY, rotation: rotation,
                                                    segments: 64)
            return ProjectedEntity(shape: .polyline(points: points, closed: true), layer: layer)
        case let .polygon(_, center, radius, sides, rotation):
            let points = SketchEntity.polygonPoints(center: center, radius: radius,
                                                    sides: sides, rotation: rotation)
            return ProjectedEntity(shape: .polyline(points: points, closed: true), layer: layer)
        case let .spline(_, points, closed):
            let polyline = SketchEntity.splinePoints(points, closed: closed)
            return ProjectedEntity(shape: .polyline(points: polyline, closed: closed), layer: layer)
        }
    }

    // MARK: - Circular chain recognition

    /// Replaces connected line chains that are convincingly circular with a
    /// single `.circle`/`.arc` entity. Guards against mistaking polygons for
    /// circles with the resident residual AND the average chord/radius ratio
    /// (a 12-gon or coarser stays lines). Exact analytic radii, when present,
    /// override the tessellation fit.
    private func circularize(_ entities: [ProjectedEntity],
                             exact: [(center: SIMD2<Double>, radius: Double)])
        -> [ProjectedEntity] {
        guard let bounds = entityBounds(entities) else { return entities }
        let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)
        let quantum = max(1e-6, extent * 1e-5)

        var nodeIndex: [NodeKey: Int] = [:]
        var nodePoints: [SIMD2<Double>] = []
        func node(for point: SIMD2<Double>) -> Int {
            let key = NodeKey(x: MeshQuantize.key64(point.x, quantum: quantum),
                              y: MeshQuantize.key64(point.y, quantum: quantum))
            if let existing = nodeIndex[key] { return existing }
            let id = nodePoints.count
            nodeIndex[key] = id
            nodePoints.append(point)
            return id
        }

        var segments: [(Int, Int)] = []
        var segmentEntityIndex: [Int] = []
        for (index, entity) in entities.enumerated() {
            guard case let .line(a, b) = entity.shape else { continue }
            let first = node(for: a)
            let second = node(for: b)
            guard first != second else { continue }
            segments.append((first, second))
            segmentEntityIndex.append(index)
        }
        guard segments.count >= 8 else { return entities }

        var adjacency: [Int: [Int]] = [:]
        for (segmentIndex, segment) in segments.enumerated() {
            adjacency[segment.0, default: []].append(segmentIndex)
            adjacency[segment.1, default: []].append(segmentIndex)
        }

        var visited = [Bool](repeating: false, count: segments.count)
        var replacements: [Int: ProjectedEntity] = [:]
        var consumed = Set<Int>()
        for start in segments.indices where !visited[start] {
            var stack = [start]
            visited[start] = true
            var component: [Int] = []
            while let segmentIndex = stack.popLast() {
                component.append(segmentIndex)
                for nodeID in [segments[segmentIndex].0, segments[segmentIndex].1] {
                    for other in adjacency[nodeID] ?? [] where !visited[other] {
                        visited[other] = true
                        stack.append(other)
                    }
                }
            }
            guard component.count >= 8 else { continue }
            var componentPoints: [SIMD2<Double>] = []
            var seenNodes = Set<Int>()
            for segmentIndex in component {
                for nodeID in [segments[segmentIndex].0, segments[segmentIndex].1]
                where seenNodes.insert(nodeID).inserted {
                    componentPoints.append(nodePoints[nodeID])
                }
            }
            guard let fit = fitCircle(componentPoints) else { continue }
            guard fit.maxResidual <= max(0.005, 0.003 * fit.radius) else { continue }
            let averageChord = component.reduce(0.0) { partial, segmentIndex in
                partial + simd_distance(nodePoints[segments[segmentIndex].0],
                                        nodePoints[segments[segmentIndex].1])
            } / Double(component.count)
            guard averageChord <= 0.35 * fit.radius else { continue }
            guard let span = angularSpan(componentPoints, around: fit.center) else { continue }

            let firstEntityIndex = segmentEntityIndex[component[0]]
            if span.maxGap <= 0.5 {
                var center = fit.center
                var radius = fit.radius
                if let match = exact.first(where: {
                    simd_distance($0.center, fit.center) <= max(0.05, 0.02 * fit.radius)
                        && abs($0.radius - fit.radius) <= max(0.05, 0.02 * fit.radius)
                }) {
                    center = match.center
                    radius = match.radius
                }
                replacements[firstEntityIndex] = ProjectedEntity(
                    shape: .circle(center: center, radius: radius),
                    layer: entities[firstEntityIndex].layer)
                for segmentIndex in component.dropFirst() {
                    consumed.insert(segmentEntityIndex[segmentIndex])
                }
            } else if span.maxGap <= 2 * Double.pi - 0.15 {
                var center = fit.center
                var radius = fit.radius
                if let match = exact.first(where: {
                    simd_distance($0.center, fit.center) <= max(0.05, 0.02 * fit.radius)
                        && abs($0.radius - fit.radius) <= max(0.05, 0.02 * fit.radius)
                }) {
                    center = match.center
                    radius = match.radius
                }
                replacements[firstEntityIndex] = ProjectedEntity(
                    shape: .arc(center: center, radius: radius,
                                startAngle: span.startAngle, endAngle: span.endAngle),
                    layer: entities[firstEntityIndex].layer)
                for segmentIndex in component.dropFirst() {
                    consumed.insert(segmentEntityIndex[segmentIndex])
                }
            }
        }

        var output: [ProjectedEntity] = []
        output.reserveCapacity(entities.count)
        for (index, entity) in entities.enumerated() {
            if let replacement = replacements[index] {
                output.append(replacement)
                continue
            }
            if consumed.contains(index) { continue }
            output.append(entity)
        }
        return output
    }

    /// Kasa (algebraic least-squares) circle fit. For exactly co-circular
    /// points — kernel tessellation vertices ARE on the curve — this recovers
    /// the true center/radius; a nearly-collinear set is refused by the
    /// determinant guard.
    private func fitCircle(_ points: [SIMD2<Double>]) -> FittedCircle? {
        guard points.count >= 3 else { return nil }
        let count = Double(points.count)
        var mean = SIMD2<Double>.zero
        for point in points { mean += point }
        mean /= count
        var suu = 0.0, svv = 0.0, suv = 0.0
        var suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        var sumSquares = 0.0
        for point in points {
            let u = point.x - mean.x
            let v = point.y - mean.y
            suu += u * u
            svv += v * v
            suv += u * v
            suuu += u * u * u
            svvv += v * v * v
            suvv += u * v * v
            svuu += v * u * u
            sumSquares += u * u + v * v
        }
        let determinant = suu * svv - suv * suv
        let magnitude = max(suu + svv, 1e-12)
        guard abs(determinant) > 1e-12 * magnitude * magnitude else { return nil }
        let d = suuu + suvv
        let e = svvv + svuu
        let du = (d * svv - e * suv) / determinant
        let dv = (e * suu - d * suv) / determinant
        let center = SIMD2(mean.x - du / 2, mean.y - dv / 2)
        let radiusSquared = (du * du + dv * dv) / 4 + sumSquares / count
        guard radiusSquared > 1e-12 else { return nil }
        let radius = radiusSquared.squareRoot()
        var residual = 0.0
        for point in points {
            residual = max(residual, abs(simd_distance(point, center) - radius))
        }
        return FittedCircle(center: center, radius: radius, maxResidual: residual)
    }

    /// Largest angular gap of `points` around `center` plus the arc endpoints
    /// bounding it (CCW from `startAngle` to `endAngle` covers everything but
    /// the gap).
    private func angularSpan(_ points: [SIMD2<Double>], around center: SIMD2<Double>)
        -> (maxGap: Double, startAngle: Double, endAngle: Double)? {
        guard points.count >= 2 else { return nil }
        var angles = points.map { atan2($0.y - center.y, $0.x - center.x) }
        angles = angles.map { $0 < 0 ? $0 + 2 * Double.pi : $0 }.sorted()
        var maxGap = 0.0
        var gapIndex = 0
        for index in angles.indices {
            let next = index + 1 < angles.count ? angles[index + 1]
                                                : angles[0] + 2 * Double.pi
            let gap = next - angles[index]
            if gap > maxGap {
                maxGap = gap
                gapIndex = index
            }
        }
        return (maxGap, angles[(gapIndex + 1) % angles.count], angles[gapIndex])
    }

    /// Exact circular rims from the bodies' analytic B-reps: cylindrical faces
    /// whose axis is parallel to the view normal project as true circles. Used
    /// to replace the Float32 tessellation fit with the kernel radius.
    private func exactCylinderCircles(bodies: [Body], plane: SketchPlane,
                                      normal: SIMD3<Double>)
        -> [(center: SIMD2<Double>, radius: Double)] {
        let view = simd_normalize(normal)
        var circles: [(center: SIMD2<Double>, radius: Double)] = []
        for body in bodies {
            guard let brep = body.brep, body.transform.scale > 1e-12 else { continue }
            for info in OCCTKernel.faceInfo(brep) {
                guard let signature = info.signature,
                      case let .cylindrical(radius) = signature.kind,
                      radius > 1e-12 else { continue }
                let axis = body.transform.rotation.act(info.normal)
                guard simd_length(axis) > 1e-9 else { continue }
                guard abs(simd_dot(simd_normalize(axis), view)) > 1 - 1e-6 else { continue }
                let center = plane.toLocal(body.transform.applying(to: info.centroid))
                guard center.x.isFinite, center.y.isFinite else { continue }
                circles.append((center, radius * body.transform.scale))
            }
        }
        return circles
    }

    private func dedupe(_ entities: [ProjectedEntity]) -> [ProjectedEntity] {
        guard let bounds = entityBounds(entities) else { return entities }
        let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)
        let tolerance = max(1e-6, extent * 1e-6)
        var output: [ProjectedEntity] = []
        var seenLines: [(SIMD2<Double>, SIMD2<Double>)] = []
        var seenCircles: [(SIMD2<Double>, Double)] = []
        for entity in entities {
            switch entity.shape {
            case let .line(a, b):
                let duplicate = seenLines.contains {
                    sameSegment($0.0, $0.1, a, b, tolerance: tolerance)
                }
                if duplicate { continue }
                seenLines.append((a, b))
            case let .circle(center, radius):
                let duplicate = seenCircles.contains {
                    simd_distance($0.0, center) <= tolerance
                        && abs($0.1 - radius) <= tolerance
                }
                if duplicate { continue }
                seenCircles.append((center, radius))
            case .arc, .polyline:
                break
            }
            output.append(entity)
        }
        return output
    }

    private func sameSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                             _ c: SIMD2<Double>, _ d: SIMD2<Double>,
                             tolerance: Double) -> Bool {
        (simd_distance(a, c) <= tolerance && simd_distance(b, d) <= tolerance)
            || (simd_distance(a, d) <= tolerance && simd_distance(b, c) <= tolerance)
    }

    // MARK: - Dimensions

    private func dimensions(for page: CADDrawingPage,
                            projection: PageProjection) -> [DrawingDimension] {
        if !projection.views.isEmpty {
            return projection.views.flatMap { item in
                dimensions(entities: item.entities, scale: item.view.scale)
            }
        }
        return dimensions(entities: projection.entities, scale: page.scale)
    }

    private func dimensions(entities: [ProjectedEntity],
                            scale rawScale: Double) -> [DrawingDimension] {
        let scale = rawScale.isFinite && rawScale > 0 ? rawScale : 1
        var dims: [DrawingDimension] = []
        guard let bounds = entityBounds(entities) else { return dims }
        let width = bounds.max.x - bounds.min.x
        let height = bounds.max.y - bounds.min.y
        if width > 1e-9 {
            dims.append(linearDimension(axis: "x", value: width / scale, bounds: bounds))
        }
        if height > 1e-9 {
            dims.append(linearDimension(axis: "y", value: height / scale, bounds: bounds))
        }
        for circle in detectedCircles(entities: entities) {
            if circle.isFull {
                dims.append(diameterDimension(circle, scale: scale))
            } else {
                dims.append(radiusDimension(circle, scale: scale))
            }
        }
        return dims
    }

    /// Circles/arcs visible on the page: circle/arc entities (including the
    /// ones `circularize` recognized) plus closed section loops that fit a
    /// circle. Duplicates from coincident geometry collapse to one.
    private func detectedCircles(_ projection: PageProjection) -> [DetectedCircle] {
        detectedCircles(entities: projection.entities)
    }

    private func detectedCircles(entities: [ProjectedEntity]) -> [DetectedCircle] {
        var circles: [DetectedCircle] = []
        for entity in entities {
            switch entity.shape {
            case let .circle(center, radius):
                circles.append(DetectedCircle(center: center, radius: radius, isFull: true))
            case let .arc(center, radius, _, _):
                circles.append(DetectedCircle(center: center, radius: radius, isFull: false))
            case let .polyline(points, closed):
                guard closed, points.count >= 8, let fit = fitCircle(points) else { continue }
                guard fit.maxResidual <= max(0.005, 0.003 * fit.radius) else { continue }
                guard let span = angularSpan(points, around: fit.center),
                      span.maxGap <= 0.5 else { continue }
                circles.append(DetectedCircle(center: fit.center, radius: fit.radius,
                                              isFull: true))
            case .line:
                break
            }
        }
        var unique: [DetectedCircle] = []
        for circle in circles {
            let duplicate = unique.contains {
                simd_distance($0.center, circle.center) <= max(1e-4, 1e-4 * circle.radius)
                    && abs($0.radius - circle.radius) <= max(1e-4, 1e-4 * circle.radius)
            }
            if !duplicate { unique.append(circle) }
        }
        return unique
    }

    private func linearDimension(axis: String, value: Double,
                                 bounds: (min: SIMD2<Double>, max: SIMD2<Double>))
        -> DrawingDimension {
        let offset = 8.0
        if axis == "x" {
            let y = bounds.min.y - offset
            let line = (SIMD2(bounds.min.x, y), SIMD2(bounds.max.x, y))
            let extensionA = (bounds.min, SIMD2(bounds.min.x, y - 1.5))
            let extensionB = (SIMD2(bounds.max.x, bounds.min.y), SIMD2(bounds.max.x, y - 1.5))
            return DrawingDimension(
                kind: "linear", axis: axis, value: value, text: formatLength(value),
                textPosition: SIMD2((bounds.min.x + bounds.max.x) / 2, y + 1.2),
                center: nil, radius: nil, leader: nil,
                extensionLines: [extensionA, extensionB], dimensionLine: line)
        }
        let x = bounds.min.x - offset
        let line = (SIMD2(x, bounds.min.y), SIMD2(x, bounds.max.y))
        let extensionA = (bounds.min, SIMD2(x - 1.5, bounds.min.y))
        let extensionB = (SIMD2(bounds.max.x, bounds.min.y), SIMD2(x - 1.5, bounds.max.y))
        return DrawingDimension(
            kind: "linear", axis: axis, value: value, text: formatLength(value),
            textPosition: SIMD2(x - 1.2, (bounds.min.y + bounds.max.y) / 2),
            center: nil, radius: nil, leader: nil,
            extensionLines: [extensionA, extensionB], dimensionLine: line)
    }

    private func diameterDimension(_ circle: DetectedCircle, scale: Double) -> DrawingDimension {
        let value = circle.radius * 2 / scale
        let direction = simd_normalize(SIMD2<Double>(1, 1))
        let onCircle = circle.center + direction * circle.radius
        let outward = circle.center + direction * (circle.radius + 6)
        return DrawingDimension(
            kind: "diameter", axis: nil, value: value, text: "Ø" + formatLength(value),
            textPosition: outward + direction * 1.0,
            center: circle.center, radius: circle.radius / scale,
            leader: (onCircle, outward), extensionLines: [], dimensionLine: nil)
    }

    private func radiusDimension(_ circle: DetectedCircle, scale: Double) -> DrawingDimension {
        let value = circle.radius / scale
        let direction = simd_normalize(SIMD2<Double>(1, 1))
        let onCircle = circle.center + direction * circle.radius
        let outward = circle.center + direction * (circle.radius + 6)
        return DrawingDimension(
            kind: "radius", axis: nil, value: value, text: "R" + formatLength(value),
            textPosition: outward + direction * 1.0,
            center: circle.center, radius: value,
            leader: (onCircle, outward), extensionLines: [], dimensionLine: nil)
    }

    private func centerlineSegments(_ projection: PageProjection)
        -> [(SIMD2<Double>, SIMD2<Double>)] {
        var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
        for circle in detectedCircles(projection) where circle.isFull {
            let arm = circle.radius * 1.3
            segments.append((SIMD2(circle.center.x - arm, circle.center.y),
                             SIMD2(circle.center.x + arm, circle.center.y)))
            segments.append((SIMD2(circle.center.x, circle.center.y - arm),
                             SIMD2(circle.center.x, circle.center.y + arm)))
        }
        return segments
    }

    // MARK: - Annotation resolution

    private struct ManufacturingHoleMetadata {
        var spec: HoleSpec
        var pilotDiameterMM: Double?
        var through: Bool
        var holeDepthMM: Double?
        var counterboreDiameterMM: Double?
        var counterboreDepthMM: Double?
        var countersinkDiameterMM: Double?
        var countersinkAngleDegrees: Double?
    }

    private struct ResolvedAnnotations {
        var balloons: [[String: Any]] = []
        var manualDimensions: [[String: Any]] = []
        var annotations: [[String: Any]] = []
        var manufacturingAnnotations: [[String: Any]] = []
        var issues: [String] = []

        var rows: [[String: Any]] { manualDimensions }
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private func point2(_ raw: Any?) -> SIMD2<Double>? {
        guard let values = doubleArray(raw), values.count == 2,
              values.allSatisfy(\.isFinite) else { return nil }
        return SIMD2(values[0], values[1])
    }

    /// Live world transform of one placed instance for THIS page, including
    /// the page's named exploded offset. Nil when the instance or source body
    /// no longer resolves.
    private func instanceWorldTransform(instance: CADAssemblyInstance,
                                        source: Body,
                                        page: CADDrawingPage) -> Transform3D? {
        guard let assembly = loadAssemblyValue(),
              let occurrence = assembly.occurrence(instance.id, viewID: page.explodedViewID) else {
            return nil
        }
        let placement = occurrence.explodedWorldTransform ?? occurrence.worldTransform
        guard placement.isPlaceable else { return nil }
        return placement.placement3D().composed(onto: source.transform)
    }

    private func inverseApply(_ point: SIMD3<Double>, _ transform: Transform3D) -> SIMD3<Double>? {
        guard transform.scale.isFinite, abs(transform.scale) > 1e-12 else { return nil }
        return transform.rotation.inverse.act(point - transform.translation) / transform.scale
    }

    private func bodyLocalPointFromDrawing(_ drawing: SIMD2<Double>,
                                           page: CADDrawingPage,
                                           plane: SketchPlane,
                                           world: Transform3D,
                                           source: Body) -> SIMD3<Double>? {
        bodyLocalPointFromDrawing(drawing, plane: plane, scale: page.scale,
                                  world: world, source: source)
    }

    private func bodyLocalPointFromDrawing(_ drawing: SIMD2<Double>,
                                           plane: SketchPlane,
                                           scale: Double,
                                           world: Transform3D,
                                           source: Body) -> SIMD3<Double>? {
        guard scale.isFinite, scale > 0 else { return nil }
        let modelPoint = plane.origin + plane.xAxis * (drawing.x / scale)
            + plane.yAxis * (drawing.y / scale)
        guard let bodyLocal = inverseApply(modelPoint, world) else { return nil }
        // `world` already includes the source body transform; the stored
        // binding is body-local, which is the document's part frame.
        _ = source
        return bodyLocal
    }

    private func drawingPointFromBodyLocal(_ local: SIMD3<Double>,
                                           page: CADDrawingPage,
                                           plane: SketchPlane,
                                           world: Transform3D) -> SIMD2<Double>? {
        drawingPointFromBodyLocal(local, plane: plane, scale: page.scale, world: world)
    }

    private func drawingPointFromBodyLocal(_ local: SIMD3<Double>,
                                           plane: SketchPlane,
                                           scale: Double,
                                           world: Transform3D) -> SIMD2<Double>? {
        guard scale.isFinite, scale > 0 else { return nil }
        let point = plane.toLocal(world.applying(to: local))
        return point * scale
    }

    private func instanceBounds(_ instanceID: UUID,
                                projection: PageProjection)
        -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        guard let instance = projection.instances.first(where: { $0.id == instanceID }) else {
            return nil
        }
        return entityBounds(instance.entities)
    }

    private func autoBalloonAnchor(instanceID: UUID,
                                   page: CADDrawingPage,
                                   projection: PageProjection,
                                   viewID: UUID? = nil) -> SIMD2<Double> {
        if let sheetBounds = instanceBounds(instanceID, page: page,
                                            projection: projection, viewID: viewID) {
            let offset = projection.views.first { item in
                viewID.map { id in id == item.view.id } ?? true
            }?.offset ?? .zero
            let bounds = (min: sheetBounds.min - offset, max: sheetBounds.max - offset)
            return SIMD2(bounds.max.x + 12, bounds.max.y + 12)
        }
        return SIMD2(max(page.paperWidthMM * 0.5, 20), max(page.paperHeightMM * 0.5, 20))
    }

    private func defaultDimensionTextPosition(kind: CADDrawingDimensionKind,
                                              points: [SIMD2<Double>]) -> SIMD2<Double> {
        guard let first = points.first else { return SIMD2(10, 10) }
        if points.count >= 2 {
            let delta = points[1] - first
            let length = simd_length(delta)
            if length > 1e-9 {
                let normal = SIMD2(-delta.y, delta.x) / length
                return (first + points[1]) / 2 + normal * 7
            }
        }
        return first + SIMD2(6, 6)
    }

    private func resolvedBalloons(page: CADDrawingPage,
                                  projection: PageProjection) -> [[String: Any]] {
        let assembly = loadAssemblyValue()
        return page.balloons.map { balloon -> [String: Any] in
            let context = viewContext(for: page, projection: projection,
                                      viewID: balloon.viewID)
            let sheetAnchor = balloon.anchor + context.offset
            let entry = page.bom?.entry(id: balloon.bomEntryID ?? UUID())
                ?? page.bom?.entry(itemNumber: balloon.itemNumber)
            let instance = balloon.instanceID.flatMap { assembly?.instance($0) }
            var target = balloon.target.map { $0 + context.offset }
            var stale = false
            var invalid = false
            var reasons: [String] = []
            if let entry, entry.itemNumber != balloon.itemNumber {
                stale = true
                reasons.append("BOM item number changed.")
            }
            if let pageBOM = page.bom, !pageBOM.entries.isEmpty, entry == nil {
                stale = true
                reasons.append("Balloon item \(balloon.itemNumber) is not in the current BOM.")
            }
            if let instance {
                if let source = body(for: effectiveBodyID(instance)), source.isHidden {
                    stale = true
                    reasons.append("The source body is hidden.")
                }
                if target == nil {
                    if let bounds = instanceBounds(instance.id, page: page,
                                                   projection: projection,
                                                   viewID: context.view.id) {
                        target = nearestBoundaryPoint(to: sheetAnchor, bounds: bounds)
                    } else {
                        stale = true
                        reasons.append("The instance has no projected geometry in this view.")
                        target = sheetAnchor + SIMD2(10, 10)
                    }
                }
            } else {
                invalid = true
                reasons.append("The associated assembly instance no longer exists.")
                target = target ?? sheetAnchor + SIMD2(10, 10)
            }
            if let entry {
                let live = entry.instanceIDs.compactMap { assembly?.instance($0) }
                let matching: [CADAssemblyInstance]
                if let identity = entry.partDefinitionID {
                    matching = live.filter { $0.bomIdentity == identity }
                } else {
                    matching = live.filter { effectiveBodyID($0) == entry.bodyID }
                }
                var seen = Set<UUID>()
                var liveCount = 0
                for instance in matching where seen.insert(instance.id).inserted {
                    liveCount += 1
                }
                if liveCount != entry.quantity {
                    stale = true
                    reasons.append("The item quantity differs from the captured BOM.")
                }
            }
            var row: [String: Any] = [
                "id": balloon.id.uuidString,
                "itemNumber": balloon.itemNumber,
                "text": balloon.text ?? "\(balloon.itemNumber)",
                "anchor": pointPayload(sheetAnchor),
                "target": pointPayload(target ?? sheetAnchor),
                "localAnchor": pointPayload(balloon.anchor),
                "stale": stale,
                "invalid": invalid,
                "bomEntryID": ((entry?.id.uuidString ?? balloon.bomEntryID?.uuidString) as Any?) ?? NSNull(),
                "instanceID": (balloon.instanceID?.uuidString as Any?) ?? NSNull(),
            ]
            if balloon.viewID != nil || !context.isLegacy {
                row["viewID"] = context.view.id.uuidString
            }
            if !reasons.isEmpty { row["reasons"] = reasons }
            return row
        }
    }

    private func instanceBounds(_ instanceID: UUID,
                                page: CADDrawingPage,
                                projection: PageProjection,
                                viewID: UUID?) -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        if let viewID,
           let item = projection.views.first(where: { $0.view.id == viewID }) {
            guard let instance = item.instances.first(where: { $0.id == instanceID }) else {
                return nil
            }
            return entityBounds(instance.entities)
        }
        return instanceBounds(instanceID, projection: projection)
    }

    private func nearestBoundaryPoint(to point: SIMD2<Double>,
                                      bounds: (min: SIMD2<Double>, max: SIMD2<Double>))
        -> SIMD2<Double> {
        let clamped = simd_clamp(point, bounds.min, bounds.max)
        if clamped != point { return clamped }
        // Anchor inside the projected part: exit toward the nearest side.
        let candidates = [
            SIMD2(bounds.min.x, point.y), SIMD2(bounds.max.x, point.y),
            SIMD2(point.x, bounds.min.y), SIMD2(point.x, bounds.max.y),
        ]
        return candidates.min { simd_length($0 - point) < simd_length($1 - point) } ?? clamped
    }

    private struct ResolvedViewContext {
        var view: CADDrawingSheetView
        var offset: SIMD2<Double>
        var plane: SketchPlane?
        var scale: Double
        var isLegacy: Bool
        var entities: [ProjectedEntity] = []
    }

    private func viewContext(for page: CADDrawingPage,
                             projection: PageProjection,
                             viewID: UUID?) -> ResolvedViewContext {
        let projected = projection.views.first { item in
            viewID.map { $0 == item.view.id } ?? true
        } ?? projection.views.first
        if let projected {
            return ResolvedViewContext(view: projected.view,
                                       offset: projected.offset,
                                       plane: plane(for: page, view: projected.view),
                                       scale: projected.view.scale,
                                       isLegacy: false,
                                       entities: projected.entities)
        }
        let view = page.effectiveSheetViews.first { item in
            viewID.map { $0 == item.id } ?? true
        } ?? page.effectiveSheetViews[0]
        return ResolvedViewContext(view: view, offset: .zero,
                                   plane: plane(for: page, view: view),
                                   scale: view.scale,
                                   isLegacy: page.sheetViews == nil,
                                   entities: projection.entities)
    }

    private struct ResolvedFeatureFace {
        var faceIndex: Int
        var radiusMM: Double
        var currentRevision: UInt64
        var drawingCenter: SIMD2<Double>
        var drawingRadius: Double
    }

    private enum FeatureFaceResolution {
        case success(ResolvedFeatureFace)
        case failure(String)
    }

    /// Identity gate for a captured feature reference. While provenance names
    /// the authoring feature, the SAME active feature must still own the
    /// linked source body and the captured sketch links must still exist;
    /// otherwise the dimension DANGLES instead of falling back to a
    /// geometric guess. Returns the failure message, or nil when the
    /// reference carries no feature provenance (imported faces keep the
    /// honest anchor-only ambiguity handling below) or the provenance is
    /// still live. Measurement authority stays with the kernel face; this
    /// gate only protects identity.
    private func provenanceGateFailure(_ feature: CADDrawingFeatureReference,
                                       source: Body) -> String? {
        guard let featureID = feature.featureID else { return nil }
        let features = document.session.document.features
        guard let node = features.node(FeatureID(raw: featureID)) else {
            return "The linked feature no longer exists "
                   + "(the hole feature was deleted); the dimension is dangling."
        }
        guard !node.suppressed else {
            return "The linked feature is suppressed; the dimension is dangling."
        }
        guard Self.featureNode(node, writesBody: source.id) else {
            return "The linked feature no longer owns this source body; "
                   + "the dimension is dangling."
        }
        if let sketchID = feature.sketchID {
            guard node.referencedSketchIDs.contains(SketchID(raw: sketchID)) else {
                return "The linked sketch is not a source of this feature; the dimension is dangling."
            }
            guard let sketch = document.session.document.sketches
                .first(where: { $0.id == SketchID(raw: sketchID) }) else {
                return "The linked feature's authoring sketch no longer exists; "
                       + "the dimension is dangling."
            }
            if let entityID = feature.sketchEntityID {
                guard let entity = sketch.entities.first(where: { $0.id == entityID }) else {
                    return "The linked sketch entity no longer exists; the dimension is dangling."
                }
                guard case .circle = entity else {
                    return "The linked entity is no longer a circle; the dimension is dangling."
                }
            }
        }
        return nil
    }

    /// The captured authoring circle, still live in the document, or nil when
    /// this reference carries no usable entity provenance (feature-level-only
    /// or imported references). Callers must run `provenanceGateFailure`
    /// first so a MISSING sketch/entity dangles instead of degrading to
    /// anchor-only matching.
    private func provenanceCircle(_ feature: CADDrawingFeatureReference)
        -> (radius: Double, center: SIMD2<Double>, plane: SketchPlane)? {
        guard let sketchID = feature.sketchID,
              let sketch = document.session.document.sketches
                .first(where: { $0.id == SketchID(raw: sketchID) }),
              let entityID = feature.sketchEntityID,
              let entity = sketch.entities.first(where: { $0.id == entityID }),
              case let .circle(_, center, radius) = entity else { return nil }
        return (radius: radius, center: center, plane: sketch.plane)
    }

    /// - Parameter allowLiveProvenanceStationDrift: Manufacturing callouts are
    ///   bound to a mechanical-hole feature whose live spec is their semantic
    ///   authority; a parameter edit may legitimately trim the captured pilot
    ///   face and move its centroid along the axis. Only those callers pass
    ///   `true`. A linked DIMENSION keeps the captured axial station as part of
    ///   its face identity.
    private func resolveFeatureFace(_ feature: CADDrawingFeatureReference,
                                    page: CADDrawingPage,
                                    context: ResolvedViewContext,
                                    allowLiveProvenanceStationDrift: Bool = false)
        -> FeatureFaceResolution {
        guard let plane = context.plane else {
            return .failure("The view has no valid projection plane.")
        }
        let assembly = loadAssemblyValue()
        let source: Body?
        let world: Transform3D?
        if let requestedInstanceID = feature.instanceID {
            guard let instance = assembly?.instance(requestedInstanceID) else {
                return .failure("The linked assembly instance no longer exists.")
            }
            guard let resolved = body(for: effectiveBodyID(instance)) else {
                return .failure("The linked instance's source body no longer exists.")
            }
            guard let placement = instanceWorldTransform(instance: instance,
                                                         source: resolved, page: page) else {
                return .failure("The linked instance no longer has a placeable transform.")
            }
            source = resolved
            world = placement
        } else if let resolved = body(for: feature.bodyID) {
            source = resolved
            world = resolved.transform
        } else {
            return .failure("The linked source body no longer exists.")
        }
        guard let source, let world else {
            return .failure("The linked source body no longer resolves.")
        }
        guard let brep = source.brep else {
            return .failure("The linked source no longer has an analytic B-rep.")
        }
        // Identity authority: while this reference captured the authoring
        // feature/sketch entity, the SAME active feature must still own this
        // geometry or the dimension DANGLES. A geometric fallback can adopt a
        // different plausible unique coaxial cylinder (a counterbore left at
        // the same station after the measured hole is gone), so provenance is
        // checked before any face is considered.
        if let failure = provenanceGateFailure(feature, source: source) {
            return .failure(failure)
        }
        let anchorAxis = simd_normalize(feature.anchor.direction)
        let worldAxis = simd_normalize(world.rotation.act(anchorAxis))
        let viewNormal = simd_normalize(plane.normal)
        guard abs(simd_dot(worldAxis, viewNormal)) >= 0.995 else {
            return .failure("The view is not looking along the linked cylinder's axis.")
        }
        let tolerance = max(feature.anchor.toleranceMM, 0.05)
        // A cylindrical face is a candidate when it shares the captured axis
        // and radial station. `requireStation` also demands the captured axial
        // position: that is the right identity test for a bare geometric
        // anchor, but NOT sufficient for a live authoring feature. A
        // legitimate parameter edit can shorten the very bore it authored (a
        // counterbore-depth change moves the remaining pilot face's centroid
        // along the axis) while its radius, axis and radial station stay
        // exact. The provenance check below re-locates that bore by identity.
        func cylindricalMatches(requireStation: Bool)
            -> [(face: OCCTKernel.KernelFaceInfo, radius: Double)] {
            var found: [(face: OCCTKernel.KernelFaceInfo, radius: Double)] = []
            for face in OCCTKernel.faceInfo(brep) {
                guard let signature = face.signature,
                      case let .cylindrical(radius) = signature.kind else { continue }
                let axis = simd_normalize(signature.normal)
                guard abs(simd_dot(anchorAxis, axis)) >= 0.995 else { continue }
                // Compare the AXIAL position, not the radial centroid: a
                // half-cylinder's centroid moves inward/outward when its radius
                // changes, while the hole's axis and axial station do not.
                let delta = signature.centroid - feature.anchor.centroid
                let axialDelta = abs(simd_dot(delta, anchorAxis))
                let radial = delta - simd_dot(delta, anchorAxis) * anchorAxis
                // A partial cylindrical face's centroid sits off-axis and moves
                // with the radius; allow that bounded radial drift but still
                // reject a different bore at the same axial station.
                let radialLimit = max(tolerance,
                                      0.5 * max(radius, feature.anchor.radiusMM ?? radius))
                guard simd_length(radial) <= radialLimit else { continue }
                guard !requireStation || axialDelta <= tolerance else { continue }
                found.append((face: face, radius: radius))
            }
            return found
        }

        let strictMatches = cylindricalMatches(requireStation: true)
        // When the captured provenance names the authoring sketch circle, the
        // surviving match must be the SAME cylinder that entity describes:
        // same axis, a bounded radial station and a consistent radius. A
        // linked dimension additionally requires the captured axial station
        // (part of the strict scan); the manufacturing-only re-location below
        // relaxes that one attribute when the live hole feature still authors
        // the bore. The entity may legitimately change radius (Ø10 → Ø8
        // remeasures on the SAME feature); a face that only shares axis and
        // station but not the entity's cylinder (e.g. the coaxial counterbore
        // left behind after a hole edit consumed the measured band) is a
        // DIFFERENT cylinder and dangles instead of adopting its value. The
        // displayed measurement still comes from the live kernel face below,
        // never from the entity.
        var matches = strictMatches
        if let entity = provenanceCircle(feature) {
            let radiusLimit = max(0.25,
                                  0.05 * max(entity.radius,
                                             feature.anchor.radiusMM ?? entity.radius))
            func provenanceConsistent(
                _ candidate: (face: OCCTKernel.KernelFaceInfo, radius: Double)
            ) -> Bool {
                guard let signature = candidate.face.signature,
                      case let .cylindrical(radius) = signature.kind else { return false }
                guard abs(simd_dot(simd_normalize(signature.normal), anchorAxis)) >= 0.995 else {
                    return false
                }
                // Radial station, never the captured axial station: the live
                // circle still identifies this bore when an edit only changes
                // how much of the same bore remains.
                let delta = signature.centroid - feature.anchor.centroid
                let radial = delta - simd_dot(delta, anchorAxis) * anchorAxis
                guard simd_length(radial) <= max(tolerance, radius * 0.5) else { return false }
                return abs(radius - entity.radius) <= radiusLimit
            }
            let strictProvenanceMatches = strictMatches.filter(provenanceConsistent)
            if strictProvenanceMatches.isEmpty, allowLiveProvenanceStationDrift {
                // The authoring circle is still live, but the captured face
                // moved along the axis (for example, a counterbore depth edit
                // shortens the remaining pilot bore and moves that face's
                // centroid). A manufacturing callout follows the live hole
                // feature, so re-locate the SAME bore by axis, live radius and
                // radial station. A genuinely deleted or replaced cylinder
                // still fails below: no face of that radius remains.
                matches = cylindricalMatches(requireStation: false)
                    .filter(provenanceConsistent)
            } else {
                matches = strictProvenanceMatches
            }
            // Classify an empty result BEFORE the count == 1 ambiguity guard.
            // An empty set is never "several valid faces": it means the strict
            // station scan found NO face at all (the captured cylinder is
            // missing) or it found faces but none is the captured cylinder
            // (the live feature no longer owns this geometry). The original
            // absent / provenance-lost messages stay exact.
            if matches.isEmpty {
                if strictMatches.isEmpty {
                    return .failure("The linked cylindrical face no longer exists "
                                    + "(the hole feature was deleted or the topology changed).")
                }
                return .failure("The linked feature no longer owns this geometry "
                                + "(the captured cylinder is gone); the dimension is dangling.")
            }
        } else {
            guard !matches.isEmpty else {
                return .failure("The linked cylindrical face no longer exists "
                                + "(the hole feature was deleted or the topology changed).")
            }
        }
        guard matches.count == 1, let match = matches.first else {
            return .failure("The linked cylindrical face is ambiguous after the source change; "
                            + "re-select the feature.")
        }
        var center = plane.toLocal(world.applying(to: match.face.centroid)) * context.scale
        var drawingRadius = match.radius * context.scale
        // Refine the projected centre from the view's detected circle when
        // available: a partial cylindrical face's centroid is radially offset
        // from the hole axis, while the projected circle centre is the true
        // axis point. Match by radius and a bounded distance, never by a bare
        // index.
        if !context.entities.isEmpty {
            let expectedRadius = match.radius * context.scale
            let candidates = detectedCircles(entities: context.entities).filter { circle in
                guard circle.isFull else { return false }
                let radiusDelta = abs(circle.radius - expectedRadius)
                let limit = max(0.05, max(expectedRadius, circle.radius) * 0.02)
                return radiusDelta <= limit
                    && simd_distance(circle.center, center)
                        <= max(2.0, expectedRadius * 0.75)
            }
            if let nearest = candidates.min(by: {
                simd_distance($0.center, center) < simd_distance($1.center, center)
            }) {
                center = nearest.center
                drawingRadius = nearest.radius
            }
        }
        return .success(ResolvedFeatureFace(faceIndex: match.face.index,
                                            radiusMM: match.radius,
                                            currentRevision: source.meshRevision,
                                            drawingCenter: center,
                                            drawingRadius: drawingRadius))
    }

    // MARK: - Manufacturing resolution

    /// Resolve every manufacturing annotation against the LIVE document. A
    /// resolved callout exposes its display lines and computed limits; a
    /// stale/dangling callout exposes no old measured value, only an explicit
    /// STALE/— marker and the reason.
    private func resolvedManufacturingAnnotations(page: CADDrawingPage,
                                                  projection: PageProjection)
        -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for annotation in page.manufacturingAnnotations {
            let context = viewContext(for: page, projection: projection,
                                      viewID: annotation.viewID)
            var stale = false
            var invalid = false
            var dangling = false
            var status = "resolved"
            var reasons: [String] = []
            var target: SIMD2<Double>?
            var resolvedFeature: [String: Any]?
            if let feature = annotation.feature {
                switch resolveFeatureFace(feature, page: page, context: context,
                                          allowLiveProvenanceStationDrift: true) {
                case .success(let live):
                    target = live.drawingCenter
                    resolvedFeature = [
                        "faceIndex": live.faceIndex,
                        "radiusMM": live.radiusMM,
                        "currentRevision": live.currentRevision,
                    ]
                case .failure(let message):
                    dangling = true
                    status = "dangling"
                    reasons.append(message)
                }
            } else if annotation.kind.requiresHoleSource {
                dangling = true
                status = "dangling"
                reasons.append("This callout needs a linked mechanical hole.")
            }

            var display: [String: Any] = [:]
            var computed: [String: Any] = [:]
            switch annotation.kind {
            case .datumFeature:
                guard let datum = annotation.datum else {
                    invalid = true
                    reasons.append("The stored datum payload is missing.")
                    break
                }
                display["letter"] = datum.letter
                if let explicit = datum.leaderTarget {
                    target = explicit
                }
            case .featureControlFrame:
                guard let frame = annotation.featureControlFrame else {
                    invalid = true
                    reasons.append("The stored feature-control frame is missing.")
                    break
                }
                display["characteristic"] = frame.characteristic.rawValue
                display["characteristicTitle"] = frame.characteristic.title
                display["diameterZone"] = frame.diameterZone
                // A GD&T zone is a tolerance, not a nominal size: page
                // precision is a floor so a valid 0.001 never prints as 0.00.
                display["toleranceText"] =
                    CADDrawingManufacturingRules.featureControlToleranceText(
                        frame.toleranceMM, diameterZone: frame.diameterZone,
                        pagePrecision: page.displayPrecision)
                if let condition = frame.materialCondition,
                   condition != .regardless {
                    display["materialCondition"] = condition.rawValue
                    display["materialConditionCode"] = condition.shortCode
                }
                display["datumReferences"] = frame.datumReferences.map {
                    reference -> [String: Any] in
                    var row: [String: Any] = ["letter": reference.letter]
                    if let modifier = reference.modifier, modifier != .regardless {
                        row["modifier"] = modifier.rawValue
                        row["modifierCode"] = modifier.shortCode
                    }
                    return row
                }
                if let explicit = frame.leaderTarget {
                    target = explicit
                }
            case .surfaceFinish:
                guard let finish = annotation.surfaceFinish else {
                    invalid = true
                    reasons.append("The stored surface-finish payload is missing.")
                    break
                }
                // Roughness is a tolerance-like value: 0.025 µm must not round
                // to 0.03/0.00 at a 2 dp page. The exact µm value stays in
                // `computed` for metadata/native consumers.
                display["raText"] = CADDrawingManufacturingRules.surfaceFinishRaText(
                    finish.raMicrometres, pagePrecision: page.displayPrecision)
                display["allAround"] = finish.allAround
                if let method = finish.machiningMethod { display["machiningMethod"] = method }
                computed["raMicrometres"] = finish.raMicrometres
            case .weld:
                guard let weld = annotation.weld else {
                    invalid = true
                    reasons.append("The stored weld payload is missing.")
                    break
                }
                display["weldType"] = weld.type.rawValue
                display["weldTypeTitle"] = weld.type.title
                display["sizeText"] = formatDisplayLength(weld.sizeMM, page: page)
                if let length = weld.lengthMM {
                    display["lengthText"] = formatDisplayLength(length, page: page)
                }
                if let pitch = weld.pitchMM {
                    display["pitchText"] = formatDisplayLength(pitch, page: page)
                }
                display["allAround"] = weld.allAround
                display["fieldWeld"] = weld.fieldWeld
                if let tail = weld.tailNote { display["tailNote"] = tail }
                if let explicit = weld.leaderTarget { target = explicit }
            case .threadCallout:
                guard let thread = annotation.thread else {
                    invalid = true
                    reasons.append("The stored thread payload is missing.")
                    break
                }
                display["designation"] = thread.designation
                display["pitchMM"] = thread.pitchMM
                display["threadClass"] = thread.threadClass
                display["handedness"] = thread.handedness.rawValue
                display["through"] = thread.through
                display["geometricThread"] = false
                if dangling {
                    display["textLines"] = ["STALE"]
                    break
                }
                guard let feature = annotation.feature else {
                    dangling = true
                    status = "dangling"
                    reasons.append("This thread callout has no linked hole.")
                    display["textLines"] = ["STALE"]
                    break
                }
                let holeResult = holeMetadata(feature)
                guard case let .success(hole) = holeResult else {
                    var reason = "The linked hole metadata could not be resolved."
                    if case let .failure(error) = holeResult { reason = error.message }
                    stale = true
                    status = "stale"
                    reasons.append(reason)
                    display["textLines"] = ["STALE"]
                    break
                }
                let issues = CADDrawingManufacturingRules.validateThread(
                    thread, kind: nil, value: nil,
                    pilotDiameterMM: hole.pilotDiameterMM,
                    sourceThrough: hole.through,
                    sourceDepthMM: hole.holeDepthMM)
                if !issues.isEmpty {
                    stale = true
                    status = "stale"
                    reasons.append(contentsOf: issues)
                    display["textLines"] = ["STALE"]
                    break
                }
                var lines: [String] = [threadDesignationText(thread)]
                if thread.handedness == .leftHand { lines[0] += " LH" }
                if thread.through {
                    lines.append("THRU")
                } else if let depth = thread.depthMM {
                    lines.append("DEPTH " + formatDisplayLength(depth, page: page))
                }
                display["textLines"] = lines
                display["verification"] = CADDrawingManufacturingRules.threadVerification(
                    thread: thread, pilotDiameterMM: hole.pilotDiameterMM) ?? "linkedHole"
                if let pilot = hole.pilotDiameterMM {
                    computed["pilotDiameterMM"] = pilot
                }
                computed["holeThrough"] = hole.through
                if let depth = hole.holeDepthMM {
                    computed["holeDepthMM"] = depth
                }
            case .counterboreCallout:
                computed["geometricThread"] = false
                if dangling {
                    display["textLines"] = ["STALE"]
                    break
                }
                guard let feature = annotation.feature else {
                    dangling = true
                    status = "dangling"
                    reasons.append("This counterbore callout has no linked hole.")
                    display["textLines"] = ["STALE"]
                    break
                }
                let holeResult = holeMetadata(feature)
                guard case let .success(hole) = holeResult else {
                    var reason = "The linked hole metadata could not be resolved."
                    if case let .failure(error) = holeResult { reason = error.message }
                    stale = true
                    status = "stale"
                    reasons.append(reason)
                    display["textLines"] = ["STALE"]
                    break
                }
                guard hole.spec.kind == .counterbore,
                      let diameter = hole.counterboreDiameterMM,
                      let depth = hole.counterboreDepthMM else {
                    stale = true
                    status = "stale"
                    reasons.append("The linked hole is no longer a counterbore.")
                    display["textLines"] = ["STALE"]
                    break
                }
                var lines: [String] = [
                    "CBORE Ø" + formatDisplayLength(diameter, page: page),
                    "DEPTH " + formatDisplayLength(depth, page: page),
                ]
                if hole.through {
                    lines.append("THRU")
                } else if let pilotDepth = hole.holeDepthMM {
                    lines.append("PILOT DEPTH " + formatDisplayLength(pilotDepth, page: page))
                }
                if let pilot = hole.pilotDiameterMM {
                    lines.append("PILOT Ø" + formatDisplayLength(pilot, page: page))
                }
                display["textLines"] = lines
                computed["counterboreDiameterMM"] = diameter
                computed["counterboreDepthMM"] = depth
                computed["holeThrough"] = hole.through
                if let pilot = hole.pilotDiameterMM {
                    computed["pilotDiameterMM"] = pilot
                }
            }
            if !annotation.payloadIsExclusive {
                invalid = true
                reasons.append("The stored annotation payload is not exclusive to its kind.")
            }
            if invalid { status = "invalid" }
            let localPosition = annotation.position
            var row: [String: Any] = [
                "id": annotation.id.uuidString,
                "kind": annotation.kind.rawValue,
                "kindTitle": annotation.kind.title,
                "position": pointPayload(localPosition + context.offset),
                "localPosition": pointPayload(localPosition),
                "heightMM": annotation.heightMM,
                "stale": stale,
                "invalid": invalid,
                "dangling": dangling,
                "status": status,
                "display": display,
                "configured": configuredPayload(annotation),
            ]
            if annotation.viewID != nil || !context.isLegacy {
                row["viewID"] = context.view.id.uuidString
            }
            if let target {
                row["target"] = pointPayload(target + context.offset)
            }
            if let feature = annotation.feature {
                row["feature"] = featurePayload(feature)
            }
            if let resolvedFeature { row["resolvedFeature"] = resolvedFeature }
            if !computed.isEmpty { row["computed"] = computed }
            if !reasons.isEmpty { row["reasons"] = reasons }
            rows.append(row)
        }
        return rows
    }

    private func threadDesignationText(_ thread: CADDrawingThreadCallout) -> String {
        let parsed = CADDrawingManufacturingRules.parseThreadDesignation(thread.designation)
        let nominal = parsed?.nominalMM ?? 0
        let pitch: String
        if abs(thread.pitchMM - thread.pitchMM.rounded()) < 1e-9 {
            pitch = String(format: "%.1f", thread.pitchMM)
        } else {
            pitch = CADDrawingManufacturingRules.formatNumber(thread.pitchMM)
        }
        return "M" + CADDrawingManufacturingRules.formatNumber(nominal) + "×" + pitch
            + "-" + thread.threadClass
    }

    private func configuredPayload(_ annotation: CADDrawingManufacturingAnnotation)
        -> [String: Any] {
        var object: [String: Any] = [
            "kind": annotation.kind.rawValue,
            "position": pointPayload(annotation.position),
            "heightMM": annotation.heightMM,
        ]
        if let viewID = annotation.viewID { object["viewID"] = viewID.uuidString }
        if let feature = annotation.feature { object["feature"] = featurePayload(feature) }
        if let datum = annotation.datum, let value = jsonObject(datum) {
            object["datum"] = value
        }
        if let frame = annotation.featureControlFrame, let value = jsonObject(frame) {
            object["featureControlFrame"] = value
        }
        if let finish = annotation.surfaceFinish, let value = jsonObject(finish) {
            object["surfaceFinish"] = value
        }
        if let weld = annotation.weld, let value = jsonObject(weld) {
            object["weld"] = value
        }
        if let thread = annotation.thread, let value = jsonObject(thread) {
            object["thread"] = value
        }
        if let counterbore = annotation.counterbore, let value = jsonObject(counterbore) {
            object["counterbore"] = value
        }
        return object
    }

    private func resolvedManualDimensions(page: CADDrawingPage,
                                          projection: PageProjection)
        -> ResolvedAnnotations {
        var result = ResolvedAnnotations()
        let assembly = loadAssemblyValue()
        for dimension in page.manualDimensions {
            let context = viewContext(for: page, projection: projection, viewID: dimension.viewID)
            var points = dimension.drawingPoints
            var value: Double? = dimension.value
            var textPosition = dimension.textPosition
            var stale = false
            var invalid = false
            var dangling = false
            var remeasured = false
            var status = "resolved"
            var reasons: [String] = []
            var currentRevision: UInt64?
            var resolvedFeature: [String: Any]?
            if let feature = dimension.feature {
                switch resolveFeatureFace(feature, page: page, context: context) {
                case .success(let live):
                    currentRevision = live.currentRevision
                    let oldCenter = points.first ?? live.drawingCenter
                    let direction: SIMD2<Double>
                    if points.count >= 2 {
                        let delta = points[1] - points[0]
                        direction = simd_length(delta) > 1e-9
                            ? simd_normalize(delta) : SIMD2(1, 0)
                    } else {
                        direction = SIMD2(1, 0)
                    }
                    points = [live.drawingCenter,
                              live.drawingCenter + direction * live.drawingRadius]
                    textPosition += live.drawingCenter - oldCenter
                    value = dimension.kind == .diameter
                        ? live.radiusMM * 2 : live.radiusMM
                    let revisionChanged = dimension.feature?.sourceRevision
                        .map { $0 != live.currentRevision } ?? true
                    remeasured = abs((value ?? 0) - dimension.value) > 1e-9 || revisionChanged
                    status = "resolved"
                    resolvedFeature = [
                        "faceIndex": live.faceIndex,
                        "radiusMM": live.radiusMM,
                        "currentRevision": live.currentRevision,
                    ]
                case .failure(let message):
                    dangling = true
                    value = nil
                    status = "dangling"
                    reasons.append(message)
                }
            } else if let binding = dimension.binding {
                let instance = binding.instanceID.flatMap { assembly?.instance($0) }
                let source = binding.bodyID.flatMap { body(for: $0) }
                    ?? instance.flatMap { body(for: effectiveBodyID($0)) }
                if let instance, let source {
                    currentRevision = source.meshRevision
                    if let recorded = binding.sourceRevision, recorded != source.meshRevision {
                        stale = true
                        reasons.append("The source part changed since this dimension was placed.")
                    }
                    if let plane = context.plane,
                       let world = instanceWorldTransform(instance: instance,
                                                          source: source, page: page) {
                        let live = binding.modelPoints.compactMap {
                            drawingPointFromBodyLocal($0, plane: plane,
                                                      scale: context.scale, world: world)
                        }
                        if !live.isEmpty, live.count == points.count {
                            let delta = live[0] - points[0]
                            points = live
                            textPosition += delta
                            value = measuredValue(kind: dimension.kind,
                                                  points: binding.modelPoints)
                            if !delta.x.isFinite || !delta.y.isFinite { invalid = true }
                        } else {
                            invalid = true
                            value = nil
                            reasons.append("The bound part geometry no longer projects.")
                        }
                    } else {
                        invalid = true
                        value = nil
                        reasons.append("The view or instance transform is invalid.")
                    }
                } else {
                    invalid = true
                    value = nil
                    reasons.append("The bound instance or source body no longer exists.")
                }
            } else {
                reasons.append("This dimension is not bound to a part; it will not follow the model.")
            }
            if invalid { status = "invalid" }
            var toleranceDisplay: CADDrawingToleranceDisplay?
            var toleranceWarning: String?
            if let tolerance = dimension.tolerance, !dangling, !invalid, let value {
                if let display = CADDrawingManufacturingRules.formatTolerance(
                    tolerance, nominalMM: value, kind: dimension.kind,
                    unit: page.displayUnit, precision: page.displayPrecision) {
                    toleranceDisplay = display
                    if !display.consistentWithNominal {
                        toleranceWarning = "The live nominal is outside the stored absolute limits."
                    }
                } else {
                    toleranceWarning = "The stored tolerance is invalid for the live value."
                }
            }
            var text: String
            if let override = dimension.textOverride {
                text = override
            } else if dangling {
                text = dimension.kind == .diameter ? "Ø—"
                    : (dimension.kind == .radius ? "R—" : "—")
            } else if invalid {
                text = "—"
            } else {
                text = dimensionText(kind: dimension.kind, value: value ?? 0, page: page)
                if let suffix = toleranceDisplay?.primarySuffix {
                    text += " " + suffix
                }
            }
            let sheetPosition = textPosition + context.offset
            var row: [String: Any] = [
                "id": dimension.id.uuidString,
                "kind": dimension.kind.rawValue,
                "value": (value.map { $0 as Any }) ?? (NSNull() as Any),
                "unit": dimension.kind == .angle ? "deg" : "mm",
                "text": text,
                // The native editor saves view-local values. The sheet-space
                // point above is for hit-testing/rendering; these are the
                // exact stored fields, so an edit round-trip never shifts a
                // multi-view dimension by the view offset.
                "localTextPosition": pointPayload(textPosition),
                "textPosition": pointPayload(sheetPosition),
                "drawingPoints": points.map(pointPayload),
                "sheetPoints": points.map { pointPayload($0 + context.offset) },
                "stale": stale,
                "invalid": invalid,
                "dangling": dangling,
                "remeasured": remeasured,
                "status": status,
                "unbound": dimension.binding == nil && dimension.feature == nil,
                "binding": bindingPayload(dimension.binding,
                                          currentRevision: currentRevision),
            ]
            if dimension.viewID != nil || !context.isLegacy {
                row["viewID"] = context.view.id.uuidString
            }
            if let feature = dimension.feature {
                row["feature"] = featurePayload(feature)
            }
            // Raw stored override (the displayed `text` also carries the
            // tolerance suffix). The editor needs the original value so an
            // unrelated tolerance edit never promotes formatted display text
            // into a permanent text override.
            if let override = dimension.textOverride {
                row["textOverride"] = override
            }
            if let resolvedFeature { row["resolvedFeature"] = resolvedFeature }
            if let tolerance = dimension.tolerance {
                row["tolerance"] = tolerancePayload(tolerance)
            }
            if let toleranceDisplay {
                row["toleranceDisplay"] = toleranceDisplayPayload(toleranceDisplay)
            }
            if let toleranceWarning { row["toleranceWarning"] = toleranceWarning }
            if !reasons.isEmpty { row["reasons"] = reasons }
            result.manualDimensions.append(row)
            if stale || invalid || dangling {
                result.issues.append("Dimension \(dimension.id.uuidString): "
                                     + reasons.joined(separator: " "))
            }
        }
        result.balloons = resolvedBalloons(page: page, projection: projection)
        result.annotations = page.annotations.map {
            annotationRow($0, page: page, projection: projection)
        }
        result.manufacturingAnnotations = resolvedManufacturingAnnotations(
            page: page, projection: projection)
        for row in result.manufacturingAnnotations
        where (row["stale"] as? Bool == true) || (row["invalid"] as? Bool == true)
            || (row["dangling"] as? Bool == true) {
            let reasons = row["reasons"] as? [String] ?? []
            result.issues.append("Manufacturing annotation \(row["id"] as? String ?? "?"): "
                                 + reasons.joined(separator: " "))
        }
        return result
    }

    private func featurePayload(_ feature: CADDrawingFeatureReference) -> [String: Any] {
        var object: [String: Any] = [
            "kind": feature.kind.rawValue,
            "bodyID": feature.bodyID.uuidString,
            "anchor": [
                "centroid": vectorPayload(feature.anchor.centroid),
                "direction": vectorPayload(feature.anchor.direction),
                "toleranceMM": feature.anchor.toleranceMM,
            ],
        ]
        if let radius = feature.anchor.radiusMM { object["radiusMM"] = radius }
        if let instanceID = feature.instanceID { object["instanceID"] = instanceID.uuidString }
        if let featureID = feature.featureID { object["featureID"] = featureID.uuidString }
        if let sketchID = feature.sketchID { object["sketchID"] = sketchID.uuidString }
        if let sketchEntityID = feature.sketchEntityID {
            object["sketchEntityID"] = sketchEntityID.uuidString
        }
        if let sourceRevision = feature.sourceRevision {
            object["sourceRevision"] = sourceRevision
        }
        return object
    }

    private func annotationRow(_ annotation: CADDrawingTextAnnotation,
                               page: CADDrawingPage,
                               projection: PageProjection) -> [String: Any] {
        let assembly = loadAssemblyValue()
        let context = viewContext(for: page, projection: projection,
                                  viewID: annotation.viewID)
        var position = annotation.position
        var stale = false
        var invalid = false
        var reasons: [String] = []
        var currentRevision: UInt64?
        if let binding = annotation.binding,
           let instance = binding.instanceID.flatMap({ assembly?.instance($0) }),
           let source = binding.bodyID.flatMap({ body(for: $0) }) ?? body(for: effectiveBodyID(instance)),
           let local = binding.modelPoints.first {
            currentRevision = source.meshRevision
            if let recorded = binding.sourceRevision, recorded != source.meshRevision {
                stale = true
                reasons.append("The source part changed since this annotation was placed.")
            }
            if let plane = context.plane,
               let world = instanceWorldTransform(instance: instance, source: source, page: page),
               let live = drawingPointFromBodyLocal(local, plane: plane,
                                                    scale: context.scale, world: world) {
                position = live
            } else {
                invalid = true
                reasons.append("The bound instance no longer projects on this page.")
            }
        }
        var row: [String: Any] = [
            "id": annotation.id.uuidString,
            "text": annotation.text,
            "position": pointPayload(position + context.offset),
            "localPosition": pointPayload(position),
            "heightMM": annotation.heightMM,
            "stale": stale,
            "invalid": invalid,
            "binding": bindingPayload(annotation.binding, currentRevision: currentRevision),
        ]
        if annotation.viewID != nil || !context.isLegacy {
            row["viewID"] = context.view.id.uuidString
        }
        if !reasons.isEmpty { row["reasons"] = reasons }
        return row
    }

    private func bindingPayload(_ binding: CADDrawingBinding?,
                                currentRevision: UInt64?) -> [String: Any] {
        guard let binding else { return ["bound": false] }
        var object: [String: Any] = [
            "bound": true,
            "modelPointCount": binding.modelPoints.count,
        ]
        if let instanceID = binding.instanceID { object["instanceID"] = instanceID.uuidString }
        if let bodyID = binding.bodyID { object["bodyID"] = bodyID.uuidString }
        if let sourceRevision = binding.sourceRevision { object["sourceRevision"] = sourceRevision }
        if let currentRevision { object["currentRevision"] = currentRevision }
        return object
    }

    private func measuredValue(kind: CADDrawingDimensionKind,
                               points: [SIMD3<Double>]) -> Double {
        switch kind {
        case .length:
            guard points.count >= 2 else { return 0 }
            return simd_distance(points[0], points[1])
        case .angle:
            guard points.count >= 3 else { return 0 }
            let a = points[1] - points[0]
            let b = points[2] - points[0]
            guard simd_length(a) > 1e-12, simd_length(b) > 1e-12 else { return 0 }
            return acos(min(max(simd_dot(simd_normalize(a), simd_normalize(b)), -1), 1))
                * 180 / .pi
        case .radius:
            guard points.count >= 2 else { return 0 }
            return simd_distance(points[0], points[1])
        case .diameter:
            guard points.count >= 2 else { return 0 }
            return simd_distance(points[0], points[1]) * 2
        }
    }

    private func dimensionText(kind: CADDrawingDimensionKind, value: Double) -> String {
        switch kind {
        case .length: return "\(formatLength(value)) mm"
        case .angle: return "\(formatLength(value))°"
        case .radius: return "R\(formatLength(value))"
        case .diameter: return "Ø\(formatLength(value))"
        }
    }

    /// Template-aware annotation text. Geometry is still stored millimetres;
    /// `units`/`precision` change only the displayed value. A page without a
    /// template keeps the historical trimmed millimetre spelling.
    private func dimensionText(kind: CADDrawingDimensionKind, value: Double,
                               page: CADDrawingPage) -> String {
        switch kind {
        case .length:
            return "\(formatDisplayLength(value, page: page)) \(page.displayUnit.symbol)"
        case .angle:
            return "\(formatDisplayAngle(value, page: page))°"
        case .radius:
            return "R\(formatDisplayLength(value, page: page))"
        case .diameter:
            return "Ø\(formatDisplayLength(value, page: page))"
        }
    }

    private func formatDisplayLength(_ millimetres: Double, page: CADDrawingPage) -> String {
        guard millimetres.isFinite else { return "—" }
        let value = page.units == nil
            ? millimetres
            : page.displayUnit.displayValue(millimetres: millimetres)
        if let precision = page.displayPrecision {
            return String(format: "%.\(precision)f", value)
        }
        return formatLength(value)
    }

    private func formatDisplayAngle(_ degrees: Double, page: CADDrawingPage) -> String {
        guard degrees.isFinite else { return "—" }
        if let precision = page.displayPrecision {
            return String(format: "%.\(precision)f", degrees)
        }
        return formatLength(degrees)
    }

    private func bomReply(page: CADDrawingPage, assembly: CADAssembly?,
                          includePlacementStatus: Bool = true) -> [String: Any] {
        var rows: [[String: Any]] = []
        var issues: [String] = []
        for entry in page.bom?.entries ?? [] {
            let liveInstances = entry.instanceIDs.compactMap { assembly?.instance($0) }
            let missing = entry.instanceIDs.filter { assembly?.instance($0) == nil }
            // New rows bind the exact part definition. Legacy rows keep their
            // historical body-id match; neither path falls back to a name or
            // geometry match, so a new similarly named instance is never
            // silently substituted for a deleted one.
            let matching: [CADAssemblyInstance]
            if let identity = entry.partDefinitionID {
                matching = liveInstances.filter { $0.bomIdentity == identity }
            } else {
                matching = liveInstances.filter { effectiveBodyID($0) == entry.bodyID }
            }
            var seenInstances = Set<UUID>()
            var uniqueMatching: [CADAssemblyInstance] = []
            for instance in matching where seenInstances.insert(instance.id).inserted {
                uniqueMatching.append(instance)
            }
            let liveQuantity = uniqueMatching.count
            let body = body(for: entry.bodyID)
            let metadata = entry.partDefinitionID.flatMap {
                assembly?.partMetadataRecord($0)
            }
            // A new row is authoritative on its definition record: clearing
            // the record is a live change too. A legacy row without an
            // identity keeps its captured explicit values.
            let livePartNumber: String
            let liveMaterial: String
            let liveVersion: String
            if entry.partDefinitionID != nil {
                livePartNumber = metadata?.partNumber ?? ""
                liveMaterial = metadata?.material ?? ""
                liveVersion = metadata?.version ?? ""
            } else {
                livePartNumber = entry.partNumber
                liveMaterial = entry.material ?? ""
                liveVersion = entry.version ?? ""
            }
            let metadataChanged = livePartNumber != entry.partNumber
                || liveMaterial != (entry.material ?? "")
                || liveVersion != (entry.version ?? "")
            let stale = !missing.isEmpty || liveQuantity != entry.quantity || metadataChanged
            var row: [String: Any] = [
                "id": entry.id.uuidString,
                "itemNumber": entry.itemNumber,
                "name": body?.name ?? entry.name,
                "partNumber": livePartNumber,
                "material": liveMaterial,
                "version": liveVersion,
                "bodyID": entry.bodyID.uuidString,
                "instanceIDs": entry.instanceIDs.map(\.uuidString),
                "liveInstanceIDs": uniqueMatching.map(\.id.uuidString),
                "quantity": liveQuantity,
                "capturedQuantity": entry.quantity,
                "capturedPartNumber": entry.partNumber,
                "capturedMaterial": entry.material ?? "",
                "capturedVersion": entry.version ?? "",
                "metadataChanged": metadataChanged,
                "stale": stale,
                "missingInstanceIDs": missing.map(\.uuidString),
                "missingBody": body == nil,
            ]
            if let identity = entry.partDefinitionID {
                row["partDefinitionID"] = identity.uuidString
            } else {
                row["resolvedPartDefinitionID"] = entry.bodyID.uuidString
            }
            if !missing.isEmpty {
                issues.append("BOM item \(entry.itemNumber) is missing \(missing.count) instance(s).")
            }
            if metadataChanged {
                issues.append("BOM item \(entry.itemNumber) has updated part data; re-derive the BOM to capture it.")
            }
            rows.append(row)
        }
        var payload: [String: Any] = [
            "ok": true,
            "mutated": false,
            "showBOM": page.showBOM,
            "entries": rows,
            "entryCount": rows.count,
            "issues": issues,
        ]
        if !rows.isEmpty {
            payload["bomOutput"] = bomOutputStatus(
                page: page, rowCount: rows.count, rows: rows,
                includePlacementStatus: includePlacementStatus)
        }
        if page.bom == nil { payload["bom"] = NSNull() }
        return payload
    }

    // MARK: - Complete BOM table export

    /// Every column the complete BOM table exposes. The per-row page/view
    /// columns keep each row correlated with the selected named view and the
    /// revision the sheet was projected from; the live revision is included
    /// separately so a stale capture is visible rather than silently replaced.
    private static let bomCSVHeader: [String] = [
        "sheet", "pageID", "viewName", "viewID", "pageRevision", "liveRevision",
        "bomItemID", "itemNumber", "partDefinitionID", "name", "partNumber",
        "material", "version", "quantity", "instanceIDs", "liveInstanceIDs",
        "stale", "missingInstanceIDs", "capturedQuantity", "capturedPartNumber",
        "capturedMaterial", "capturedVersion", "metadataChanged", "missingBody",
    ]

    /// Complete UTF-8 RFC 4180 table for one drawing page. There is no row or
    /// column cap: every entry the live BOM reports is written, with its exact
    /// text (Chinese, commas, quotes and embedded newlines included). The
    /// vector sheet may have to shorten a cell visually, but this artifact does
    /// not.
    ///
    /// Values are written literally. A spreadsheet that auto-evaluates a
    /// leading `=`, `+`, `-` or `@` must import the field as text; Floe has no
    /// existing CSV formula-neutralization policy, so this export never
    /// rewrites an engineering value to a different literal.
    private func bomCSVData(page: CADDrawingPage) throws -> Data {
        // CSV is complete data, not a projected sheet layout; it needs no
        // placement/collision check and must not pay for a projection.
        let reply = bomReply(page: page, assembly: loadAssemblyValue(),
                             includePlacementStatus: false)
        let rows = (reply["entries"] as? [[String: Any]]) ?? []
        guard !rows.isEmpty else {
            throw CADDocumentError(
                code: "empty_bom",
                message: "This page has no BOM rows. Derive a BOM from the live assembly first.",
                details: ["nextAction": "Derive the BOM with drawing.setBOM, then export format=csv."])
        }
        let sheet = page.name
        let pageID = page.id.uuidString
        let viewName = page.explodedViewName ?? ""
        let viewID = page.explodedViewID?.uuidString ?? ""
        let pageRevision = page.modelRevision.map { String($0) } ?? ""
        let liveRevision = maxMeshRevision(for: page).map { String($0) } ?? ""
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        lines.append(Self.bomCSVHeader.map(csvField).joined(separator: ","))
        for row in rows {
            let partDefinitionID = (row["partDefinitionID"] as? String)
                ?? (row["resolvedPartDefinitionID"] as? String) ?? ""
            let values: [String] = [
                sheet,
                pageID,
                viewName,
                viewID,
                pageRevision,
                liveRevision,
                csvText(row["id"]),
                csvText(row["itemNumber"]),
                partDefinitionID,
                csvText(row["name"]),
                csvText(row["partNumber"]),
                csvText(row["material"]),
                csvText(row["version"]),
                csvText(row["quantity"]),
                csvList(row["instanceIDs"]),
                csvList(row["liveInstanceIDs"]),
                csvText(row["stale"]),
                csvList(row["missingInstanceIDs"]),
                csvText(row["capturedQuantity"]),
                csvText(row["capturedPartNumber"]),
                csvText(row["capturedMaterial"]),
                csvText(row["capturedVersion"]),
                csvText(row["metadataChanged"]),
                csvText(row["missingBody"]),
            ]
            guard values.count == Self.bomCSVHeader.count else {
                throw CADDocumentError(
                    code: "csv_row_width",
                    message: "The BOM table row does not match its documented columns; nothing was written.")
            }
            lines.append(values.map(csvField).joined(separator: ","))
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        guard let data = text.data(using: .utf8) else {
            throw CADDocumentError(
                code: "csv_encode_failed",
                message: "The BOM table could not be encoded as UTF-8; nothing was written.")
        }
        return data
    }

    private func csvText(_ raw: Any?) -> String {
        guard let raw, !(raw is NSNull) else { return "" }
        if let text = raw as? String { return text }
        if let number = raw as? Int { return String(number) }
        if let flag = raw as? Bool { return flag ? "true" : "false" }
        return String(describing: raw)
    }

    private func csvList(_ raw: Any?) -> String {
        (raw as? [String])?.joined(separator: ";") ?? ""
    }

    private func csvField(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasPrefix("\t") || value.hasSuffix("\t")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func pageBindingReport(page: CADDrawingPage,
                                   assembly: CADAssembly?) -> (issueCount: Int,
                                                               messages: [String],
                                                               missingInstanceIDs: [String]) {
        var messages: [String] = []
        var missing: Set<UUID> = []
        for balloon in page.balloons {
            if let id = balloon.instanceID, assembly?.instance(id) == nil {
                missing.insert(id)
                messages.append("Balloon \(balloon.itemNumber) references a missing instance.")
            }
        }
        for dimension in page.manualDimensions {
            if let feature = dimension.feature {
                let view = dimension.viewID.flatMap { id in
                    page.effectiveSheetViews.first(where: { $0.id == id })
                } ?? page.effectiveSheetViews[0]
                let context = ResolvedViewContext(view: view, offset: .zero,
                                                  plane: plane(for: page, view: view),
                                                  scale: view.scale,
                                                  isLegacy: page.sheetViews == nil)
                if case .failure(let message) = resolveFeatureFace(feature, page: page,
                                                                  context: context) {
                    messages.append("Dimension \(dimension.id.uuidString) is dangling: \(message)")
                }
                continue
            }
            if let id = dimension.binding?.instanceID, assembly?.instance(id) == nil {
                missing.insert(id)
                messages.append("Dimension \(dimension.id.uuidString) references a missing instance.")
            } else if let binding = dimension.binding,
                      let instance = binding.instanceID.flatMap({ assembly?.instance($0) }),
                      let source = body(for: effectiveBodyID(instance)),
                      let recorded = binding.sourceRevision,
                      recorded != source.meshRevision {
                messages.append("Dimension \(dimension.id.uuidString) is stale: the source part changed.")
            }
        }
        for annotation in page.annotations {
            if let id = annotation.binding?.instanceID, assembly?.instance(id) == nil {
                missing.insert(id)
                messages.append("Annotation \(annotation.id.uuidString) references a missing instance.")
            } else if let binding = annotation.binding,
                      let instance = binding.instanceID.flatMap({ assembly?.instance($0) }),
                      let source = body(for: effectiveBodyID(instance)),
                      let recorded = binding.sourceRevision,
                      recorded != source.meshRevision {
                messages.append("Annotation \(annotation.id.uuidString) is stale: the source part changed.")
            }
        }
        for annotation in page.manufacturingAnnotations {
            if let feature = annotation.feature {
                let view = annotation.viewID.flatMap { id in
                    page.effectiveSheetViews.first(where: { $0.id == id })
                } ?? page.effectiveSheetViews[0]
                let context = ResolvedViewContext(view: view, offset: .zero,
                                                  plane: plane(for: page, view: view),
                                                  scale: view.scale,
                                                  isLegacy: page.sheetViews == nil)
                if case .failure(let message) = resolveFeatureFace(
                    feature, page: page, context: context,
                    allowLiveProvenanceStationDrift: true) {
                    messages.append("Manufacturing annotation "
                                    + "\(annotation.id.uuidString) is dangling: \(message)")
                }
            } else if annotation.kind.requiresHoleSource {
                messages.append("Manufacturing annotation "
                                + "\(annotation.id.uuidString) has no linked hole.")
            }
        }
        if let viewID = page.explodedViewID, assembly?.explodedView(viewID) == nil {
            messages.append("Exploded view \(viewID.uuidString) no longer exists.")
        }
        return (messages.count, messages, missing.map(\.uuidString).sorted())
    }

    // MARK: - Shared page graphics

    /// The ONE annotation geometry path shared by the preview payload and all
    /// vector exports. Coordinates are page model-space (before the sheet
    /// placement offset); PDF/SVG/DXF add the same sheet frame on top.
    private func pageGraphics(page: CADDrawingPage,
                              projection: PageProjection) -> RenderGraphics {
        pageGraphics(page: page, projection: projection,
                     resolved: resolvedManualDimensions(page: page, projection: projection))
    }

    private func pageGraphics(page: CADDrawingPage,
                              projection: PageProjection,
                              resolved: ResolvedAnnotations) -> RenderGraphics {
        var entities = projection.entities
        var texts: [DrawingText] = []
        if page.showDimensions {
            for dim in dimensions(for: page, projection: projection) {
                for (a, b) in dim.extensionLines {
                    entities.append(ProjectedEntity(shape: .line(a, b), layer: "dimension"))
                }
                if let line = dim.dimensionLine {
                    entities.append(ProjectedEntity(shape: .line(line.0, line.1),
                                                    layer: "dimension"))
                }
                if let leader = dim.leader {
                    entities.append(ProjectedEntity(shape: .line(leader.0, leader.1),
                                                    layer: "dimension"))
                }
                texts.append(DrawingText(text: dim.text, position: dim.textPosition,
                                         height: 3.0, layer: "dimension"))
            }
        }
        if page.showCenterlines {
            for (a, b) in centerlineSegments(projection) {
                entities.append(ProjectedEntity(shape: .line(a, b), layer: "centerline"))
            }
        }
        let annotations = annotationGraphics(page: page, resolved: resolved)
        entities.append(contentsOf: annotations.entities)
        texts.append(contentsOf: annotations.texts)
        return RenderGraphics(entities: entities, texts: texts)
    }

    private func annotationGraphics(page: CADDrawingPage,
                                    resolved: ResolvedAnnotations) -> RenderGraphics {
        var entities: [ProjectedEntity] = []
        var texts: [DrawingText] = []
        for row in resolved.manualDimensions {
            guard let kindRaw = row["kind"] as? String,
                  let kind = CADDrawingDimensionKind(rawValue: kindRaw),
                  let rawPoints = (row["sheetPoints"] ?? row["drawingPoints"]) as? [[Double]],
                  let text = row["text"] as? String else { continue }
            let points = rawPoints.compactMap { values -> SIMD2<Double>? in
                guard values.count == 2 else { return nil }
                return SIMD2(values[0], values[1])
            }
            guard points.count >= 2 else { continue }
            if row["dangling"] as? Bool == true {
                if let position = row["textPosition"] as? [Double], position.count == 2 {
                    texts.append(DrawingText(text: text,
                                             position: SIMD2(position[0], position[1]),
                                             height: 3.0, layer: "dimension"))
                }
                continue
            }
            switch kind {
            case .length:
                let a = points[0], b = points[1]
                let delta = b - a
                let length = simd_length(delta)
                let normal = length > 1e-9
                    ? SIMD2(-delta.y, delta.x) / length
                    : SIMD2(0, 1)
                let offset = normal * 6
                entities.append(ProjectedEntity(
                    shape: .line(a + offset, b + offset), layer: "dimension"))
                entities.append(ProjectedEntity(
                    shape: .line(a, a + offset * 1.25), layer: "dimension"))
                entities.append(ProjectedEntity(
                    shape: .line(b, b + offset * 1.25), layer: "dimension"))
            case .angle:
                entities.append(ProjectedEntity(
                    shape: .line(points[0], points[1]), layer: "dimension"))
                if points.count >= 3 {
                    entities.append(ProjectedEntity(
                        shape: .line(points[0], points[2]), layer: "dimension"))
                }
            case .radius, .diameter:
                entities.append(ProjectedEntity(
                    shape: .line(points[0], points[1]), layer: "dimension"))
            }
            if let position = row["textPosition"] as? [Double], position.count == 2 {
                texts.append(DrawingText(text: text,
                                         position: SIMD2(position[0], position[1]),
                                         height: 3.0, layer: "dimension"))
                if let display = row["toleranceDisplay"] as? [String: Any],
                   let lines = display["lines"] as? [String] {
                    for (index, line) in lines.enumerated() {
                        texts.append(DrawingText(
                            text: line,
                            position: SIMD2(position[0],
                                            position[1] - 3.2 * Double(index + 1)),
                            height: 2.6, layer: "dimension"))
                    }
                }
            }
        }
        for row in resolved.balloons {
            guard let anchorRaw = row["anchor"] as? [Double], anchorRaw.count == 2,
                  let targetRaw = row["target"] as? [Double], targetRaw.count == 2,
                  let text = row["text"] as? String else { continue }
            let anchor = SIMD2(anchorRaw[0], anchorRaw[1])
            let target = SIMD2(targetRaw[0], targetRaw[1])
            let radius = 4.0
            let direction = target - anchor
            let length = simd_length(direction)
            let start = length > 1e-9 ? anchor + (direction / length) * radius : anchor
            entities.append(ProjectedEntity(
                shape: .circle(center: anchor, radius: radius), layer: "balloon"))
            entities.append(ProjectedEntity(
                shape: .line(start, target), layer: "balloon"))
            texts.append(DrawingText(text: text,
                                     position: anchor + SIMD2(-1.4, -1.4),
                                     height: 3.2, layer: "balloon"))
        }
        for row in resolved.annotations {
            guard let text = row["text"] as? String,
                  let position = row["position"] as? [Double], position.count == 2,
                  let height = row["heightMM"] as? Double else { continue }
            texts.append(DrawingText(text: text,
                                     position: SIMD2(position[0], position[1]),
                                     height: height, layer: "annotation"))
        }
        for row in resolved.manufacturingAnnotations {
            let graphics = manufacturingGraphics(row)
            entities.append(contentsOf: graphics.entities)
            texts.append(contentsOf: graphics.texts)
        }
        return RenderGraphics(entities: entities, texts: texts)
    }

    /// Vector symbol geometry for one resolved manufacturing annotation. Every
    /// mark is line/circle/polyline geometry, so a PDF/SVG/DXF reader never
    /// depends on a special GD&T font being installed.
    private func manufacturingGraphics(_ row: [String: Any]) -> RenderGraphics {
        guard let positionRaw = row["position"] as? [Double], positionRaw.count == 2,
              let height = row["heightMM"] as? Double, height > 0 else {
            return RenderGraphics(entities: [], texts: [])
        }
        let position = SIMD2(positionRaw[0], positionRaw[1])
        var target: SIMD2<Double>?
        if let raw = row["target"] as? [Double], raw.count == 2 {
            target = SIMD2(raw[0], raw[1])
        }
        let display = row["display"] as? [String: Any] ?? [:]
        let stale = (row["stale"] as? Bool == true)
            || (row["dangling"] as? Bool == true)
            || (row["invalid"] as? Bool == true)
        var entities: [ProjectedEntity] = []
        var texts: [DrawingText] = []
        func append(_ geometry: CADDrawingManufacturingRules.SymbolGeometry) {
            for segment in geometry.segments {
                entities.append(ProjectedEntity(shape: .line(segment.a, segment.b),
                                                layer: "annotation"))
            }
            for circle in geometry.circles {
                entities.append(ProjectedEntity(shape: .circle(center: circle.center,
                                                               radius: circle.radius),
                                                layer: "annotation"))
            }
            for polyline in geometry.polylines {
                entities.append(ProjectedEntity(shape: .polyline(points: polyline.points,
                                                                 closed: polyline.closed),
                                                layer: "annotation"))
            }
        }
        func leader(from start: SIMD2<Double>) {
            guard let target else { return }
            entities.append(ProjectedEntity(shape: .line(start, target),
                                            layer: "annotation"))
        }
        if stale {
            if let target {
                entities.append(ProjectedEntity(shape: .line(position, target),
                                                layer: "annotation"))
            }
            texts.append(DrawingText(text: "STALE", position: position,
                                     height: max(height, 2.4), layer: "annotation"))
            return RenderGraphics(entities: entities, texts: texts)
        }
        guard let kindRaw = row["kind"] as? String,
              let kind = CADDrawingManufacturingKind(rawValue: kindRaw) else {
            return RenderGraphics(entities: [], texts: [])
        }
        switch kind {
        case .datumFeature:
            let letter = display["letter"] as? String ?? "A"
            let box = height * 2.0
            let boxMin = position
            let boxMax = position + SIMD2(box, box)
            entities.append(contentsOf: rectangleEntities(min: boxMin, max: boxMax,
                                                          layer: "annotation"))
            texts.append(DrawingText(text: letter,
                                     position: SIMD2(position.x + box * 0.35,
                                                     position.y + box * 0.28),
                                     height: height, layer: "annotation"))
            if let target {
                entities.append(ProjectedEntity(
                    shape: .line(SIMD2(boxMax.x, position.y + box * 0.5), target),
                    layer: "annotation"))
                let direction = target - SIMD2(boxMax.x, position.y + box * 0.5)
                append(CADDrawingManufacturingRules.datumTriangle(
                    tip: target, from: direction, size: max(height * 0.7, 1.5)))
            }
        case .featureControlFrame:
            let frameHeight = height * 1.5
            let symbolWidth = frameHeight
            let toleranceText = display["toleranceText"] as? String ?? ""
            let toleranceWidth = max(frameHeight * 2.4,
                                     bomTextAdvance(toleranceText, height: height)
                                        + height * 1.2)
            var cells: [CGRect] = []
            var x = position.x
            cells.append(CGRect(x: CGFloat(x), y: CGFloat(position.y),
                                width: CGFloat(symbolWidth), height: CGFloat(frameHeight)))
            x += symbolWidth
            cells.append(CGRect(x: CGFloat(x), y: CGFloat(position.y),
                                width: CGFloat(toleranceWidth), height: CGFloat(frameHeight)))
            x += toleranceWidth
            let references = display["datumReferences"] as? [[String: Any]] ?? []
            for _ in references {
                let width = frameHeight * 1.3
                cells.append(CGRect(x: CGFloat(x), y: CGFloat(position.y),
                                    width: CGFloat(width), height: CGFloat(frameHeight)))
                x += width
            }
            for cell in cells {
                entities.append(contentsOf: rectangleEntities(
                    min: SIMD2(Double(cell.minX), Double(cell.minY)),
                    max: SIMD2(Double(cell.maxX), Double(cell.maxY)),
                    layer: "annotation"))
            }
            let symbolRect = cells[0]
            append(CADDrawingManufacturingRules.gdtSymbol(
                CADDrawingGDTSymbol(rawValue: display["characteristic"] as? String ?? "")
                    ?? .position,
                minimum: SIMD2(Double(symbolRect.minX) + frameHeight * 0.18,
                               Double(symbolRect.minY) + frameHeight * 0.18),
                maximum: SIMD2(Double(symbolRect.maxX) - frameHeight * 0.18,
                               Double(symbolRect.maxY) - frameHeight * 0.18)))
            texts.append(DrawingText(
                text: toleranceText,
                position: SIMD2(Double(cells[1].minX) + height * 0.6,
                                position.y + height * 0.38),
                height: height, layer: "annotation"))
            if let code = display["materialConditionCode"] as? String, code != "RFS" {
                let center = SIMD2(Double(cells[1].maxX) - height * 0.8,
                                   position.y + height * 0.55)
                entities.append(ProjectedEntity(shape: .circle(center: center,
                                                               radius: height * 0.55),
                                                layer: "annotation"))
                texts.append(DrawingText(text: code,
                                         position: center - SIMD2(height * 0.25,
                                                                  height * 0.28),
                                         height: height * 0.7, layer: "annotation"))
            }
            for (index, reference) in references.enumerated() {
                let cell = cells[index + 2]
                let letter = reference["letter"] as? String ?? "A"
                texts.append(DrawingText(
                    text: letter,
                    position: SIMD2(Double(cell.minX) + height * 0.35,
                                    position.y + height * 0.38),
                    height: height, layer: "annotation"))
                if let code = reference["modifierCode"] as? String, code != "RFS" {
                    let center = SIMD2(Double(cell.maxX) - height * 0.7,
                                       position.y + height * 0.55)
                    entities.append(ProjectedEntity(shape: .circle(center: center,
                                                                   radius: height * 0.5),
                                                    layer: "annotation"))
                    texts.append(DrawingText(text: code,
                                             position: center - SIMD2(height * 0.22,
                                                                      height * 0.26),
                                             height: height * 0.65, layer: "annotation"))
                }
            }
            leader(from: SIMD2(Double(cells[0].minX),
                               position.y + frameHeight * 0.5))
        case .surfaceFinish:
            append(CADDrawingManufacturingRules.surfaceFinishSymbol(origin: position,
                                                                     height: height))
            texts.append(DrawingText(
                text: display["raText"] as? String ?? "Ra",
                position: SIMD2(position.x + height * 4.4,
                                position.y + height * 2.0),
                height: height, layer: "annotation"))
            if let method = display["machiningMethod"] as? String {
                texts.append(DrawingText(text: method,
                                         position: SIMD2(position.x + height * 4.4,
                                                         position.y + height * 3.4),
                                         height: height * 0.75, layer: "annotation"))
            }
            if display["allAround"] as? Bool == true {
                entities.append(ProjectedEntity(shape: .circle(center: position
                                                                + SIMD2(height * 0.4,
                                                                         height * 0.4),
                                                               radius: height * 1.0),
                                                layer: "annotation"))
            }
            if let target {
                entities.append(ProjectedEntity(shape: .line(position + SIMD2(0, height),
                                                              target),
                                                layer: "annotation"))
            }
        case .weld:
            let length = height * 9
            let lineStart = position
            let lineEnd = position + SIMD2(length, 0)
            entities.append(ProjectedEntity(shape: .line(lineStart, lineEnd),
                                            layer: "annotation"))
            if let target {
                entities.append(ProjectedEntity(
                    shape: .line(SIMD2(position.x - height * 2, position.y + height * 3),
                                 target), layer: "annotation"))
                entities.append(ProjectedEntity(
                    shape: .line(SIMD2(position.x - height * 2, position.y + height * 3),
                                 SIMD2(position.x, position.y + height * 0.2)),
                    layer: "annotation"))
            }
            append(CADDrawingManufacturingRules.weldTriangle(
                origin: position + SIMD2(height * 1.4, height * 0.2),
                height: height))
            var weldText = display["sizeText"] as? String ?? ""
            if let lengthText = display["lengthText"] as? String {
                weldText += " L" + lengthText
            }
            if let pitchText = display["pitchText"] as? String {
                weldText += " P" + pitchText
            }
            texts.append(DrawingText(text: weldText,
                                     position: position + SIMD2(height * 1.4,
                                                                 height * 1.9),
                                     height: height * 0.85, layer: "annotation"))
            if display["allAround"] as? Bool == true {
                entities.append(ProjectedEntity(shape: .circle(center: position,
                                                               radius: height * 1.0),
                                                layer: "annotation"))
            }
            if display["fieldWeld"] as? Bool == true {
                let flag = position + SIMD2(length - height * 1.2, 0)
                entities.append(ProjectedEntity(shape: .polyline(
                    points: [flag, flag + SIMD2(height * 1.2, height * 1.2),
                             flag + SIMD2(height * 1.2, 0)], closed: true),
                    layer: "annotation"))
            }
            if let tail = display["tailNote"] as? String {
                texts.append(DrawingText(text: "(" + tail + ")",
                                         position: lineEnd + SIMD2(height * 0.4, 0),
                                         height: height * 0.75, layer: "annotation"))
            }
        case .threadCallout:
            if let target {
                entities.append(ProjectedEntity(shape: .line(position, target),
                                                layer: "annotation"))
            }
            let lines = display["textLines"] as? [String] ?? []
            for (index, line) in lines.enumerated() {
                texts.append(DrawingText(
                    text: line,
                    position: position + SIMD2(0, -Double(index) * height * 1.35),
                    height: height, layer: "annotation"))
            }
        case .counterboreCallout:
            append(CADDrawingManufacturingRules.counterboreSymbol(origin: position,
                                                                   height: height))
            if let target {
                entities.append(ProjectedEntity(shape: .line(position, target),
                                                layer: "annotation"))
            }
            let lines = display["textLines"] as? [String] ?? []
            for (index, line) in lines.enumerated() {
                texts.append(DrawingText(
                    text: line,
                    position: SIMD2(position.x + height * 2.9,
                                    position.y - Double(index) * height * 1.35),
                    height: height, layer: "annotation"))
            }
        }
        return RenderGraphics(entities: entities, texts: texts)
    }

    // MARK: - JSON payloads

    private func projectionPayload(page: CADDrawingPage, projection: PageProjection,
                                   mutated: Bool) -> [String: Any] {
        let dims = dimensions(for: page, projection: projection)
        let resolved = resolvedManualDimensions(page: page, projection: projection)
        let graphics = pageGraphics(page: page, projection: projection, resolved: resolved)
        var lines = 0, circles = 0, arcs = 0, polylines = 0
        for entity in graphics.entities {
            switch entity.shape {
            case .line: lines += 1
            case .circle: circles += 1
            case .arc: arcs += 1
            case .polyline: polylines += 1
            }
        }
        var counts: [String: Any] = [
            "entities": graphics.entities.count,
            "modelEntities": projection.entities.count,
            "lines": lines,
            "circles": circles,
            "arcs": arcs,
            "polylines": polylines,
            "dimensions": dims.count,
            "manualDimensions": resolved.manualDimensions.count,
            "balloons": resolved.balloons.count,
            "annotations": resolved.annotations.count,
            "manufacturingAnnotations": resolved.manufacturingAnnotations.count,
        ]
        let centerlines = page.showCenterlines ? centerlineSegments(projection) : []
        if page.showCenterlines { counts["centerlines"] = centerlines.count }
        let assembly = loadAssemblyValue()
        func instanceRow(_ instance: ProjectedInstance,
                         viewID: UUID?) -> [String: Any] {
            var row: [String: Any] = [
                "instanceID": instance.id.uuidString,
                "name": instance.name,
                "entityCount": instance.entities.count,
            ]
            if let viewID { row["viewID"] = viewID.uuidString }
            if let bounds = entityBounds(instance.entities) {
                row["bounds"] = [pointPayload(bounds.min), pointPayload(bounds.max)]
            }
            return row
        }
        let instanceRows: [[String: Any]]
        if projection.views.isEmpty {
            instanceRows = projection.instances.map { instanceRow($0, viewID: nil) }
        } else {
            instanceRows = projection.views.flatMap { item in
                item.instances.map { instanceRow($0, viewID: item.view.id) }
            }
        }
        var issues = resolved.issues
        for row in resolved.balloons where (row["stale"] as? Bool == true)
            || (row["invalid"] as? Bool == true) {
            let reasons = row["reasons"] as? [String] ?? []
            issues.append("Balloon \(row["id"] as? String ?? "?"): "
                          + reasons.joined(separator: " "))
        }
        for row in resolved.annotations where (row["stale"] as? Bool == true)
            || (row["invalid"] as? Bool == true) {
            let reasons = row["reasons"] as? [String] ?? []
            issues.append("Text \(row["id"] as? String ?? "?"): "
                          + reasons.joined(separator: " "))
        }
        for row in resolved.manufacturingAnnotations
        where (row["stale"] as? Bool == true) || (row["invalid"] as? Bool == true)
            || (row["dangling"] as? Bool == true) {
            let reasons = row["reasons"] as? [String] ?? []
            issues.append("Manufacturing \(row["id"] as? String ?? "?"): "
                          + reasons.joined(separator: " "))
        }
        let sectionIncomplete = projection.sectionIncomplete
            || projection.sectionCoverage.contains(where: { !$0.included })
        let missingExplodedView = pageMissingExplodedView(page)
        var payload: [String: Any] = [
            "ok": true,
            "mutated": mutated,
            "noRasterization": true,
            "page": pagePayload(page),
            "sectionComplete": !sectionIncomplete,
            "missingExplodedView": missingExplodedView,
            "outputBlocked": projection.outputBlocked || sectionIncomplete || missingExplodedView,
            "counts": counts,
            "entities": graphics.entities.map(entityPayload),
            "texts": graphics.texts.map(textPayload),
            "dimensions": dims.map(dimensionPayload),
            "manualDimensions": resolved.manualDimensions,
            "manualDimensionCount": resolved.manualDimensions.count,
            "balloons": resolved.balloons,
            "balloonCount": resolved.balloons.count,
            "annotations": resolved.annotations,
            "annotationCount": resolved.annotations.count,
            "manufacturingAnnotations": resolved.manufacturingAnnotations,
            "manufacturingAnnotationCount": resolved.manufacturingAnnotations.count,
            "bom": bomReply(page: page, assembly: assembly),
            "instances": instanceRows,
            "notes": projection.notes,
            "missingBodyIDs": projection.missing.map(\.uuidString),
            "missingInstanceIDs": projection.missingInstances.map(\.uuidString),
            "bindingIssues": issues,
        ]
        if !projection.views.isEmpty {
            payload["views"] = projection.views.map { item -> [String: Any] in
                var row: [String: Any] = [
                    "id": item.view.id.uuidString,
                    "name": item.view.name,
                    "kind": item.view.kind.rawValue,
                    "scale": item.view.scale,
                    "offset": pointPayload(item.offset),
                    "entityCount": item.entities.count,
                    "instanceCount": item.instances.count,
                    "sectionComplete": item.sectionComplete,
                    "notes": item.notes,
                    "missingBodyIDs": item.missing.map(\.uuidString),
                    "missingInstanceIDs": item.missingInstances.map(\.uuidString),
                ]
                row["view"] = viewPayload(item.view)
                if let bounds = item.bounds {
                    row["bounds"] = [pointPayload(bounds.min), pointPayload(bounds.max)]
                }
                if let local = item.localBounds {
                    row["localBounds"] = [pointPayload(local.min), pointPayload(local.max)]
                }
                return row
            }
            payload["viewCount"] = projection.views.count
            payload["isMultiView"] = true
        }
        if !projection.sectionCoverage.isEmpty {
            payload["sectionCoverage"] = projection.sectionCoverage.map { coverage -> [String: Any] in
                var row: [String: Any] = [
                    "bodyID": coverage.bodyID.uuidString,
                    "name": coverage.name,
                    "analyticBRep": coverage.analyticBRep,
                    "included": coverage.included,
                ]
                if let instanceID = coverage.instanceID {
                    row["instanceID"] = instanceID.uuidString
                }
                return row
            }
        }
        if !projection.viewIssues.isEmpty {
            payload["viewLayoutIssues"] = projection.viewIssues
        }
        if let viewID = page.explodedViewID {
            payload["explodedView"] = [
                "id": viewID.uuidString,
                "name": projection.explodedViewName ?? page.explodedViewName ?? "",
                "found": assembly?.explodedView(viewID) != nil,
            ]
        }
        if page.showCenterlines {
            payload["centerlines"] = centerlines.map {
                entityPayload(ProjectedEntity(shape: .line($0.0, $0.1), layer: "centerline"))
            }
        }
        return payload
    }

    private func viewPayload(_ view: CADDrawingSheetView) -> [String: Any] {
        var payload: [String: Any] = [
            "id": view.id.uuidString,
            "name": view.name,
            "kind": view.kind.rawValue,
            "scale": view.scale,
            "offset": pointPayload(view.offset),
            "viewNormal": vectorPayload(view.viewNormal),
            "viewUp": vectorPayload(view.viewUp),
            "alignment": [
                "placement": view.alignment.placement.rawValue,
                "referenceViewID": (view.alignment.referenceViewID?.uuidString as Any?) ?? NSNull(),
                "gapMM": view.alignment.gapMM,
            ],
        ]
        if let ids = view.sourceBodyIDs {
            payload["sourceBodyIDs"] = ids.map(\.uuidString)
        }
        if view.kind == .section {
            if let origin = view.sectionOrigin {
                payload["sectionOrigin"] = vectorPayload(origin)
            }
            if let normal = view.sectionNormal {
                payload["sectionNormal"] = vectorPayload(normal)
            }
        }
        if view.kind == .detail {
            if let origin = view.detailOrigin {
                payload["detailOrigin"] = vectorPayload(origin)
            }
            if let size = view.detailSizeMM {
                payload["detailSizeMM"] = [size.x, size.y]
            }
        }
        return payload
    }

    private func pagePayload(_ page: CADDrawingPage) -> [String: Any] {
        var payload: [String: Any] = [
            "id": page.id.uuidString,
            "name": page.name,
            "kind": page.kind.rawValue,
            "scale": page.scale,
            "paper": page.paper.rawValue,
            "paperWidthMM": page.paperWidthMM,
            "paperHeightMM": page.paperHeightMM,
            "title": page.title,
            "partNumbers": page.partNumbers,
            "sourceBodyIDs": page.sourceBodyIDs.map(\.uuidString),
            "viewNormal": vectorPayload(page.viewNormal),
            "viewUp": vectorPayload(page.viewUp),
            "showCenterlines": page.showCenterlines,
            "showDimensions": page.showDimensions,
            "assemblyMode": page.assemblyMode,
            "showBOM": page.showBOM,
            "balloonCount": page.balloons.count,
            "manualDimensionCount": page.manualDimensions.count,
            "annotationCount": page.annotations.count,
            "manufacturingAnnotationCount": page.manufacturingAnnotations.count,
            "viewCount": page.effectiveSheetViews.count,
            "isMultiView": page.isMultiViewSheet,
        ]
        if page.sheetViews != nil {
            payload["views"] = page.effectiveSheetViews.map { viewPayload($0) }
        }
        payload["bomEntryCount"] = page.bom?.entries.count ?? 0
        if let viewID = page.explodedViewID { payload["explodedViewID"] = viewID.uuidString }
        if let viewName = page.explodedViewName { payload["explodedViewName"] = viewName }
        if let width = page.customWidthMM { payload["customWidthMM"] = width }
        if let height = page.customHeightMM { payload["customHeightMM"] = height }
        if page.kind == .detail {
            if let origin = page.detailOrigin {
                payload["detailOrigin"] = vectorPayload(origin)
            }
            if let size = page.detailSizeMM {
                payload["detailSizeMM"] = [size.x, size.y]
            }
        } else {
            if let origin = page.sectionOrigin {
                payload["sectionOrigin"] = vectorPayload(origin)
            }
            if let normal = page.sectionNormal {
                payload["sectionNormal"] = vectorPayload(normal)
            }
        }
        if let revision = page.modelRevision { payload["modelRevision"] = revision }
        if !page.revisionRows.isEmpty {
            if let value = jsonObject(page.revisionRows) { payload["revisionRows"] = value }
        }
        if let units = page.units { payload["units"] = units.rawValue }
        if let precision = page.precision { payload["precision"] = precision }
        if let titleBlock = page.titleBlock, let value = jsonObject(titleBlock) {
            payload["titleBlock"] = value
        }
        if let binding = page.sheetTemplate {
            payload["templateID"] = binding.templateID.uuidString
            payload["templateName"] = binding.appliedName
            payload["projectionMethod"] = binding.snapshot.projection.rawValue
            if let value = jsonObject(binding.snapshot) {
                payload["template"] = value
            }
        }
        if let fingerprint = page.sourceFingerprint {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(fingerprint),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                payload["sourceFingerprint"] = object
            }
        }
        return payload
    }

    private func textPayload(_ text: DrawingText) -> [String: Any] {
        [
            "text": text.text,
            "position": pointPayload(text.position),
            "height": text.height,
            "layer": text.layer,
        ]
    }

    private func entityPayload(_ entity: ProjectedEntity) -> [String: Any] {
        var payload: [String: Any] = ["kind": entity.kindName, "layer": entity.layer]
        switch entity.shape {
        case let .line(a, b):
            payload["a"] = pointPayload(a)
            payload["b"] = pointPayload(b)
        case let .circle(center, radius):
            payload["center"] = pointPayload(center)
            payload["radius"] = radius
        case let .arc(center, radius, startAngle, endAngle):
            payload["center"] = pointPayload(center)
            payload["radius"] = radius
            payload["startAngle"] = startAngle
            payload["endAngle"] = endAngle
        case let .polyline(points, closed):
            payload["points"] = points.map { pointPayload($0) }
            payload["closed"] = closed
            if let area = entity.area { payload["area"] = area }
        }
        return payload
    }

    private func dimensionPayload(_ dim: DrawingDimension) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": dim.kind,
            "value": dim.value,
            "unit": dim.unit,
            "text": dim.text,
            "textPosition": pointPayload(dim.textPosition),
        ]
        if let axis = dim.axis { payload["axis"] = axis }
        if let center = dim.center { payload["center"] = pointPayload(center) }
        if let radius = dim.radius { payload["radius"] = radius }
        if let leader = dim.leader {
            payload["leader"] = [pointPayload(leader.0), pointPayload(leader.1)]
        }
        if let line = dim.dimensionLine {
            payload["dimensionLine"] = [pointPayload(line.0), pointPayload(line.1)]
        }
        if !dim.extensionLines.isEmpty {
            payload["extensionLines"] = dim.extensionLines.map {
                [pointPayload($0.0), pointPayload($0.1)]
            }
        }
        return payload
    }

    // MARK: - Export graphics

    private func renderGraphics(page: CADDrawingPage,
                                projection: PageProjection) -> RenderGraphics {
        let graphics = pageGraphics(page: page, projection: projection)
        // Sheet layout: model geometry in the upper-left area, clear of the
        // title block at the bottom. All exports share this placement, and the
        // preview uses the same pre-offset model space.
        let offset = sheetOffset(page: page, projection: projection,
                                 graphics: graphics)
        let placedEntities = graphics.entities.map { $0.translated(by: offset) }
        let placedTexts = graphics.texts.map {
            DrawingText(text: $0.text, position: $0.position + offset,
                        height: $0.height, layer: $0.layer)
        }
        let sheet = sheetGraphics(page: page)
        return RenderGraphics(entities: placedEntities + sheet.entities,
                              texts: placedTexts + sheet.texts,
                              lineWidthMM: sheet.lineWidthMM)
    }

    /// The one legacy sheet placement shared by rendering and BOM collision
    /// checks. A v4 shared page already carries explicit per-view offsets and
    /// must not be shifted a second time.
    private func sheetOffset(page: CADDrawingPage, projection: PageProjection,
                             graphics: RenderGraphics) -> SIMD2<Double> {
        guard page.sheetViews == nil else { return .zero }
        if let bounds = entityBounds(projection.entities)
            ?? entityBounds(graphics.entities) {
            return SIMD2(20 - bounds.min.x, 40 - bounds.min.y)
        }
        return .zero
    }

    private func sheetGraphics(page: CADDrawingPage) -> RenderGraphics {
        if let binding = page.sheetTemplate {
            return templatedSheetGraphics(page: page, binding: binding)
        }
        let geometry = bomSheetGeometry(page: page)
        let frameMin = geometry.frameMin
        let frameMax = geometry.frameMax
        var entities = rectangleEntities(min: frameMin, max: frameMax, layer: "title")
        var texts: [DrawingText] = []
        let blockMin = geometry.titleBlockMin
        let blockMax = geometry.titleBlockMax
        entities.append(contentsOf: rectangleEntities(min: blockMin, max: blockMax,
                                                      layer: "title"))
        entities.append(ProjectedEntity(
            shape: .line(SIMD2(blockMin.x + 70, blockMin.y),
                         SIMD2(blockMin.x + 70, blockMax.y)),
            layer: "title"))
        entities.append(ProjectedEntity(
            shape: .line(SIMD2(blockMin.x, blockMin.y + 11),
                         SIMD2(blockMax.x, blockMin.y + 11)),
            layer: "title"))
        texts.append(DrawingText(text: document.name,
                                 position: SIMD2(blockMin.x + 2, blockMin.y + 14),
                                 height: 5, layer: "title"))
        texts.append(DrawingText(text: page.title.isEmpty ? page.name : page.title,
                                 position: SIMD2(blockMin.x + 2, blockMin.y + 4),
                                 height: 3.5, layer: "title"))
        let scaleLabel: String
        if page.sheetViews == nil {
            scaleLabel = scaleText(page.scale)
        } else {
            let scales = page.effectiveSheetViews.map(\.scale)
            if let first = scales.first, scales.allSatisfy({ abs($0 - first) < 1e-9 }) {
                scaleLabel = scaleText(first)
            } else {
                scaleLabel = "AS SHOWN"
            }
        }
        texts.append(DrawingText(text: scaleLabel,
                                 position: SIMD2(blockMin.x + 72, blockMin.y + 14),
                                 height: 3.5, layer: "title"))
        if !page.partNumbers.isEmpty {
            texts.append(DrawingText(text: page.partNumbers.joined(separator: ", "),
                                     position: SIMD2(blockMin.x + 72, blockMin.y + 4),
                                     height: 3.5, layer: "title"))
        }
        if let viewID = page.explodedViewID,
           let view = loadAssemblyValue()?.explodedView(viewID) {
            texts.append(DrawingText(
                text: "Exploded: \(view.name)",
                position: SIMD2(frameMin.x + 2, frameMax.y - 6),
                height: 3.0, layer: "title"))
        }
        if let revision = page.modelRevision {
            texts.append(DrawingText(
                text: "Rev \(revision)",
                position: SIMD2(max(frameMin.x + 2, frameMax.x - 34), frameMax.y - 6),
                height: 3.0, layer: "title"))
        }
        if page.showBOM, let bom = page.bom, !bom.entries.isEmpty {
            let table = bomTableGraphics(page: page)
            entities.append(contentsOf: table.entities)
            texts.append(contentsOf: table.texts)
        }
        return RenderGraphics(entities: entities, texts: texts, lineWidthMM: 0.25)
    }

    /// Template-driven frame/title block. The applied page's snapshot is the
    /// authority; editing or deleting the library template cannot change it.
    private func templatedSheetGraphics(page: CADDrawingPage,
                                        binding: CADDrawingSheetTemplateBinding)
        -> RenderGraphics {
        let snapshot = binding.snapshot
        let style = CADDrawingTemplateRules.normalized(
            snapshot.style, paperWidth: page.paperWidthMM,
            paperHeight: page.paperHeightMM, revisionCount: page.revisionRows.count)
        let geometry = bomSheetGeometry(page: page)
        let frameMin = geometry.frameMin
        let frameMax = geometry.frameMax
        var entities = rectangleEntities(min: frameMin, max: frameMax, layer: "title")
        var texts: [DrawingText] = []
        let blockMin = geometry.titleBlockMin
        let blockMax = geometry.titleBlockMax
        entities.append(contentsOf: rectangleEntities(min: blockMin, max: blockMax,
                                                      layer: "title"))

        let revisionHeight = page.revisionRows.isEmpty ? 0.0
            : min(blockMax.y - blockMin.y - 8,
                  6.2 * Double(min(page.revisionRows.count, 6) + 1) + 1)
        let mainMaxY = blockMax.y
        let mainMinY = blockMin.y + revisionHeight
        if revisionHeight > 0 {
            entities.append(ProjectedEntity(
                shape: .line(SIMD2(blockMin.x, mainMinY), SIMD2(blockMax.x, mainMinY)),
                layer: "title"))
        }
        let leftWidth = (blockMax.x - blockMin.x) * 0.55
        let dividerX = blockMin.x + leftWidth
        entities.append(ProjectedEntity(
            shape: .line(SIMD2(dividerX, mainMinY), SIMD2(dividerX, mainMaxY)),
            layer: "title"))

        let baseText = style.textHeightMM
        let titleHeight = min(baseText + 1.2, max(2.4, (mainMaxY - mainMinY) * 0.32))
        texts.append(DrawingText(text: document.name,
                                 position: SIMD2(blockMin.x + 2, mainMaxY - titleHeight - 1),
                                 height: titleHeight, layer: "title"))
        let pageTitle = page.title.isEmpty ? page.name : page.title
        texts.append(DrawingText(text: pageTitle,
                                 position: SIMD2(blockMin.x + 2, mainMinY + 2.2),
                                 height: baseText, layer: "title"))

        let rightX = dividerX + 2
        var rightY = mainMaxY - baseText - 1.2
        let pageCompany = page.titleBlock?.company ?? ""
        let company = pageCompany.isEmpty ? snapshot.titleBlock.company : pageCompany
        if !company.isEmpty {
            texts.append(DrawingText(text: company,
                                     position: SIMD2(rightX, rightY),
                                     height: baseText * 0.9, layer: "title"))
            rightY -= baseText * 1.4
        }
        let pageDrawingNumber = page.titleBlock?.drawingNumber ?? ""
        let drawingNumber = pageDrawingNumber.isEmpty
            ? snapshot.titleBlock.drawingNumber : pageDrawingNumber
        if !drawingNumber.isEmpty {
            texts.append(DrawingText(text: "DWG " + drawingNumber,
                                     position: SIMD2(rightX, rightY),
                                     height: baseText * 0.85, layer: "title"))
            rightY -= baseText * 1.35
        }
        let scaleLabel: String
        if page.sheetViews == nil {
            scaleLabel = scaleText(page.scale)
        } else {
            let scales = page.effectiveSheetViews.map(\.scale)
            if let first = scales.first, scales.allSatisfy({ abs($0 - first) < 1e-9 }) {
                scaleLabel = scaleText(first)
            } else {
                scaleLabel = "AS SHOWN"
            }
        }
        let unitLabel = page.units?.symbol ?? "mm"
        let precisionLabel = page.precision.map { "\($0) dp" } ?? "legacy"
        texts.append(DrawingText(text: scaleLabel + " · " + unitLabel + " · " + precisionLabel,
                                 position: SIMD2(rightX, rightY),
                                 height: baseText * 0.75, layer: "title"))
        rightY -= baseText * 1.25
        texts.append(DrawingText(text: snapshot.projection.draftingLabel,
                                 position: SIMD2(rightX, rightY),
                                 height: baseText * 0.75, layer: "title"))
        let symbolOrigin = SIMD2(blockMax.x - 18, mainMinY + 3)
        for segment in CADDrawingManufacturingRules.projectionSymbol(
            snapshot.projection, origin: symbolOrigin, height: 2.0).segments {
            entities.append(ProjectedEntity(shape: .line(segment.a, segment.b),
                                            layer: "title"))
        }
        for circle in CADDrawingManufacturingRules.projectionSymbol(
            snapshot.projection, origin: symbolOrigin, height: 2.0).circles {
            entities.append(ProjectedEntity(shape: .circle(center: circle.center,
                                                           radius: circle.radius),
                                            layer: "title"))
        }
        for polyline in CADDrawingManufacturingRules.projectionSymbol(
            snapshot.projection, origin: symbolOrigin, height: 2.0).polylines {
            entities.append(ProjectedEntity(shape: .polyline(points: polyline.points,
                                                             closed: polyline.closed),
                                            layer: "title"))
        }
        texts.append(DrawingText(text: binding.appliedName,
                                 position: SIMD2(blockMax.x - 34, blockMax.y - 5),
                                 height: 2.4, layer: "title"))

        if !page.revisionRows.isEmpty {
            let rowHeight = revisionHeight / Double(min(page.revisionRows.count, 6) + 1)
            let headerY = blockMin.y + revisionHeight - rowHeight
            texts.append(DrawingText(text: "REV",
                                     position: SIMD2(blockMin.x + 1.2, headerY + 1.6),
                                     height: 2.3, layer: "title"))
            texts.append(DrawingText(text: "DATE",
                                     position: SIMD2(blockMin.x + 16, headerY + 1.6),
                                     height: 2.3, layer: "title"))
            texts.append(DrawingText(text: "DESCRIPTION",
                                     position: SIMD2(blockMin.x + 44, headerY + 1.6),
                                     height: 2.3, layer: "title"))
            entities.append(ProjectedEntity(
                shape: .line(SIMD2(blockMin.x + 14, blockMin.y),
                             SIMD2(blockMin.x + 14, headerY + rowHeight)),
                layer: "title"))
            entities.append(ProjectedEntity(
                shape: .line(SIMD2(blockMin.x + 42, blockMin.y),
                             SIMD2(blockMin.x + 42, headerY + rowHeight)),
                layer: "title"))
            entities.append(ProjectedEntity(
                shape: .line(SIMD2(blockMin.x, headerY),
                             SIMD2(blockMax.x, headerY)), layer: "title"))
            for (index, row) in page.revisionRows.prefix(6).enumerated() {
                let y = blockMin.y + revisionHeight - rowHeight * Double(index + 2)
                if index > 0 {
                    entities.append(ProjectedEntity(
                        shape: .line(SIMD2(blockMin.x, y + rowHeight),
                                     SIMD2(blockMax.x, y + rowHeight)), layer: "title"))
                }
                let baseline = y + 1.6
                texts.append(DrawingText(text: row.revision,
                                         position: SIMD2(blockMin.x + 1.2, baseline),
                                         height: 2.3, layer: "title"))
                texts.append(DrawingText(text: row.date,
                                         position: SIMD2(blockMin.x + 16, baseline),
                                         height: 2.3, layer: "title"))
                let description = bomFittedCell(
                    row.description,
                    availableWidth: max(10, blockMax.x - blockMin.x - 45),
                    height: 2.3).text
                texts.append(DrawingText(text: description,
                                         position: SIMD2(blockMin.x + 44, baseline),
                                         height: 2.3, layer: "title"))
            }
        }
        if style.showZoneGrid {
            let step = 50.0
            var x = frameMin.x + step
            var index = 1
            while x < frameMax.x - 5 {
                entities.append(ProjectedEntity(
                    shape: .line(SIMD2(x, frameMax.y), SIMD2(x, frameMax.y - 4)),
                    layer: "title"))
                texts.append(DrawingText(text: "\(index)",
                                         position: SIMD2(x + 1, frameMax.y - 4.2),
                                         height: 2.0, layer: "title"))
                x += step
                index += 1
            }
        }
        if page.showBOM, let bom = page.bom, !bom.entries.isEmpty {
            let table = bomTableGraphics(page: page)
            entities.append(contentsOf: table.entities)
            texts.append(contentsOf: table.texts)
        }
        return RenderGraphics(entities: entities, texts: texts,
                              lineWidthMM: style.lineWidthMM)
    }

    /// Vector BOM table. Shared instances group by part definition; the
    /// quantity is the LIVE count, so a stale captured quantity is visible in
    /// the row rather than silently reused. The table either carries every row
    /// and every required engineering column or `exportData` refuses before any
    /// bytes are produced. The preview path may draw a clearly labelled
    /// continuation instead; that partial table is never an exported artifact.
    private func bomTableGraphics(page: CADDrawingPage) -> RenderGraphics {
        // Only the rows are used here; the placement-aware status is computed
        // by the page/BOM status path, not a second time while drawing.
        let reply = bomReply(page: page, assembly: loadAssemblyValue(),
                             includePlacementStatus: false)
        let rows = (reply["entries"] as? [[String: Any]]) ?? []
        guard !rows.isEmpty else { return RenderGraphics(entities: [], texts: []) }
        let layout = bomTableLayout(page: page, rowCount: rows.count)
        guard layout.requiredColumnsFit else {
            return RenderGraphics(entities: [], texts: [])
        }
        // An incomplete preview needs one data row, the header and a labelled
        // continuation row; if there is no room for that, draw no table at all.
        if !layout.complete, layout.capacity < 2 {
            return RenderGraphics(entities: [], texts: [])
        }
        let displayRows = layout.complete
            ? rows
            : Array(rows.prefix(layout.visibleRows))
        let maxPoint = layout.maxPoint
        var entities = rectangleEntities(min: layout.minPoint, max: maxPoint, layer: "bom")
        var texts: [DrawingText] = []
        let separators: [Double] = [layout.nameX, layout.partX,
                                    layout.materialX, layout.versionX,
                                    layout.quantityX]
        for x in separators {
            guard x > layout.minPoint.x, x < maxPoint.x else { continue }
            entities.append(ProjectedEntity(
                shape: .line(SIMD2(x, layout.minPoint.y), SIMD2(x, maxPoint.y)),
                layer: "bom"))
        }
        let lastRowIndex = max(0, layout.totalRows - 1)
        for rowIndex in 0...lastRowIndex {
            let y = maxPoint.y - layout.rowHeight * Double(rowIndex)
            if rowIndex > 0 {
                entities.append(ProjectedEntity(
                    shape: .line(SIMD2(layout.minPoint.x, y), SIMD2(maxPoint.x, y)),
                    layer: "bom"))
            }
            let baseline = y - layout.rowHeight + 1.4
            if rowIndex == 0 {
                for header in bomHeaderDescriptors(layout) {
                    texts.append(DrawingText(
                        text: bomFittedCell(header.text,
                                            availableWidth: header.width - 2,
                                            height: 2.8).text,
                        position: SIMD2(header.x, baseline),
                        height: 2.8, layer: "bom"))
                }
            } else if rowIndex <= displayRows.count {
                let row = displayRows[rowIndex - 1]
                let item = row["itemNumber"] as? Int ?? rowIndex
                let quantity = row["quantity"] as? Int ?? 0
                let name = bomFittedCell((row["name"] as? String) ?? "—",
                                         availableWidth: layout.nameWidth - 2,
                                         height: 2.8).text
                let part = bomFittedCell((row["partNumber"] as? String) ?? "",
                                         availableWidth: layout.partWidth - 2,
                                         height: 2.8).text
                let material = bomFittedCell((row["material"] as? String) ?? "",
                                             availableWidth: layout.materialWidth - 2,
                                             height: 2.8).text
                let version = bomFittedCell((row["version"] as? String) ?? "",
                                            availableWidth: layout.versionWidth - 2,
                                            height: 2.8).text
                texts.append(DrawingText(
                    text: bomFittedCell("\(item)",
                                        availableWidth: layout.itemWidth - 2,
                                        height: 2.8).text,
                    position: SIMD2(layout.itemX + 1, baseline),
                    height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: name,
                                         position: SIMD2(layout.nameX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(
                    text: bomFittedCell("\(quantity)",
                                        availableWidth: layout.quantityWidth - 2,
                                        height: 2.8).text,
                    position: SIMD2(layout.quantityX + 1, baseline),
                    height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: part,
                                         position: SIMD2(layout.partX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: material,
                                         position: SIMD2(layout.materialX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: version,
                                         position: SIMD2(layout.versionX + 1, baseline),
                                         height: 2.8, layer: "bom"))
            } else {
                let shown = displayRows.count
                let range = shown == 0 ? "0" : "1–\(shown)"
                let footer = "Rows \(range) of \(rows.count) · CSV: full table"
                texts.append(DrawingText(
                    text: bomFittedCell(footer,
                                        availableWidth: layout.tableWidth - 4,
                                        height: 2.6).text,
                    position: SIMD2(layout.minPoint.x + 2, baseline),
                    height: 2.6, layer: "bom"))
            }
        }
        return RenderGraphics(entities: entities, texts: texts)
    }

    /// Sheet-space geometry and capacity for the complete BOM table. The
    /// legacy bottom-left zone is preferred; if projected drawing content
    /// occupies it, a complete table moves above the projection or to the top
    /// of the sheet instead of being drawn through model geometry. If no clear
    /// zone can hold every row, every vector format refuses with
    /// `bom_output_incomplete`; the CSV remains the full table.
    private func bomTableLayout(page: CADDrawingPage, rowCount: Int,
                                checkPlacement: Bool = true) -> BOMTableLayout {
        let base = bomTableLayoutBase(page: page, rowCount: rowCount)
        guard checkPlacement else { return base }
        // Only a complete table is exported. An incomplete preview keeps its
        // legacy zone and continuation row; export already refuses it.
        guard base.requiredColumnsFit, base.complete else { return base }
        let obstacles = bomPlacementObstacles(page: page)
        guard bomTable(base, intersects: obstacles) else { return base }
        let geometry = bomSheetGeometry(page: page)
        let topLimit = geometry.frameMax.y - 2
        let baseHeight = base.rowHeight * Double(base.totalRows)
        let bottomWidth = max(80.0, geometry.frameMax.x - geometry.frameMin.x
            - geometry.titleBlockWidth - 14)
        let textMaxY = obstacles.textBounds.map { $0.max.y }.max() ?? 0
        let allMaxY = max(obstacles.maxY, textMaxY)
        let candidates: [(minY: Double, width: Double, zone: String)] = [
            (max(geometry.frameMin.y + 2, obstacles.maxY + 2),
             base.tableWidth, "aboveProjection"),
            (max(geometry.frameMin.y + 2, allMaxY + 2),
             base.tableWidth, "aboveText"),
            (topLimit - baseHeight, base.tableWidth, "top"),
            (geometry.frameMin.y + 2, bottomWidth, "bottomLeft"),
        ]
        for candidate in candidates {
            guard candidate.minY >= geometry.frameMin.y + 2 - 1e-9,
                  candidate.minY + baseHeight <= topLimit + 1e-9 else { continue }
            let layout = bomTableLayoutBase(page: page, rowCount: rowCount,
                                            minYOverride: candidate.minY,
                                            tableWidthOverride: candidate.width,
                                            tableZone: candidate.zone)
            guard layout.complete, !bomTable(layout, intersects: obstacles) else {
                continue
            }
            return layout
        }
        // Truthful no-fit: draw no table and let status/export name the
        // missing free area rather than painting it over model geometry.
        return BOMTableLayout(
            tableWidth: base.tableWidth, rowHeight: base.rowHeight,
            minPoint: base.minPoint, maxPoint: base.minPoint,
            itemWidth: base.itemWidth, nameWidth: base.nameWidth,
            partWidth: base.partWidth, materialWidth: base.materialWidth,
            versionWidth: base.versionWidth, quantityWidth: base.quantityWidth,
            itemX: base.itemX, nameX: base.nameX, partX: base.partX,
            materialX: base.materialX, versionX: base.versionX,
            quantityX: base.quantityX, capacity: 0,
            requiredColumnsFit: true, complete: false, visibleRows: 0,
            totalRows: 0, placedAboveTitleBlock: false,
            tableZone: "none", zoneFits: false)
    }

    /// The original width/capacity selection. Overrides are used only after a
    /// complete layout collides with projected content.
    private func bomTableLayoutBase(page: CADDrawingPage, rowCount: Int,
                                    minYOverride: Double? = nil,
                                    tableWidthOverride: Double? = nil,
                                    tableZone: String? = nil) -> BOMTableLayout {
        let geometry = bomSheetGeometry(page: page)
        let frameMin = geometry.frameMin
        let frameMax = geometry.frameMax
        let rowHeight = 5.0
        let minimumColumnsWidth = 80.0
        let bottomAvailable = frameMax.x - frameMin.x - geometry.titleBlockWidth - 14
        let fullAvailable = frameMax.x - frameMin.x - 4
        var placedAboveTitleBlock = false
        var available = bottomAvailable
        var minY = frameMin.y + 2
        if let minYOverride {
            minY = max(frameMin.y + 2, minYOverride)
            if let tableWidthOverride {
                available = tableWidthOverride
            }
            placedAboveTitleBlock = tableZone == "aboveTitleBlock"
        } else if available < minimumColumnsWidth {
            guard fullAvailable >= minimumColumnsWidth else {
                return bomTableLayoutFailure(frameMin: frameMin, rowHeight: rowHeight)
            }
            placedAboveTitleBlock = true
            available = fullAvailable
            // Clear the 22 mm title block plus a small gap.
            minY = frameMin.y + 26
        }
        guard available >= minimumColumnsWidth else {
            return bomTableLayoutFailure(frameMin: frameMin, rowHeight: rowHeight)
        }
        let tableWidth = min(230.0, max(minimumColumnsWidth, available))
        let itemWidth = 8.0
        let quantityWidth = 8.0
        let extra = max(0, tableWidth - minimumColumnsWidth)
        let nameWidth = 24.0 + extra * 0.50
        let partWidth = 18.0 + extra * 0.22
        let materialWidth = 14.0 + extra * 0.20
        let versionWidth = 8.0 + extra * 0.08
        let itemX = frameMin.x + 2
        let nameX = itemX + itemWidth
        let partX = nameX + nameWidth
        let materialX = partX + partWidth
        let versionX = materialX + materialWidth
        let quantityX = versionX + versionWidth
        let minPoint = SIMD2(itemX, minY)
        let topLimit = frameMax.y - 2
        let capacity = max(0, Int(floor((topLimit - minY) / rowHeight)) - 1)
        let complete = rowCount > 0 && rowCount <= capacity
        let visibleRows = complete ? rowCount : max(0, capacity - 2)
        let totalRows = complete ? rowCount + 1 : visibleRows + 2
        let maxPoint = SIMD2(minPoint.x + tableWidth,
                             minPoint.y + rowHeight * Double(totalRows))
        return BOMTableLayout(
            tableWidth: tableWidth, rowHeight: rowHeight,
            minPoint: minPoint, maxPoint: maxPoint,
            itemWidth: itemWidth, nameWidth: nameWidth, partWidth: partWidth,
            materialWidth: materialWidth, versionWidth: versionWidth,
            quantityWidth: quantityWidth, itemX: itemX, nameX: nameX,
            partX: partX, materialX: materialX, versionX: versionX,
            quantityX: quantityX, capacity: capacity,
            requiredColumnsFit: true, complete: complete,
            visibleRows: visibleRows, totalRows: totalRows,
            placedAboveTitleBlock: placedAboveTitleBlock,
            tableZone: tableZone ?? (placedAboveTitleBlock ? "aboveTitleBlock" : "bottomLeft"))
    }

    private func bomTableLayoutFailure(frameMin: SIMD2<Double>,
                                       rowHeight: Double) -> BOMTableLayout {
        let minPoint = SIMD2(frameMin.x + 2, frameMin.y + 2)
        return BOMTableLayout(
            tableWidth: 80, rowHeight: rowHeight,
            minPoint: minPoint, maxPoint: minPoint,
            itemWidth: 8, nameWidth: 24, partWidth: 18,
            materialWidth: 14, versionWidth: 8, quantityWidth: 8,
            itemX: minPoint.x, nameX: minPoint.x,
            partX: minPoint.x, materialX: minPoint.x,
            versionX: minPoint.x, quantityX: minPoint.x,
            capacity: 0, requiredColumnsFit: false, complete: false,
            visibleRows: 0, totalRows: 0,
            placedAboveTitleBlock: false)
    }

    private func bomSheetGeometry(page: CADDrawingPage) -> BOMSheetGeometry {
        let width = max(page.paperWidthMM, 40)
        let height = max(page.paperHeightMM, 40)
        let style = page.sheetTemplate.map {
            CADDrawingTemplateRules.normalized($0.snapshot.style,
                                               paperWidth: width, paperHeight: height,
                                               revisionCount: page.revisionRows.count)
        } ?? CADDrawingSheetStyle(marginMM: 8, titleBlockWidthMM: 120,
                                  titleBlockHeightMM: 22, lineWidthMM: 0.25,
                                  textHeightMM: 3.5)
        let margin = style.marginMM
        let frameMin = SIMD2(margin, margin)
        let frameMax = SIMD2(width - margin, height - margin)
        let titleBlockWidth = min(style.titleBlockWidthMM, frameMax.x - frameMin.x)
        let titleBlockHeight = min(style.titleBlockHeightMM, frameMax.y - frameMin.y)
        return BOMSheetGeometry(
            frameMin: frameMin, frameMax: frameMax,
            titleBlockWidth: titleBlockWidth,
            titleBlockMin: SIMD2(frameMax.x - titleBlockWidth, frameMin.y),
            titleBlockMax: SIMD2(frameMax.x, frameMin.y + titleBlockHeight))
    }

    /// Projected content already placed on the sheet. Used only to choose a
    /// free BOM table zone; the same placement offset as `renderGraphics` is
    /// applied, so the check sees the actual export coordinates.
    private func bomPlacementObstacles(page: CADDrawingPage) -> BOMPlacementObstacles {
        let projection = projectPage(page)
        let graphics = pageGraphics(page: page, projection: projection)
        let offset = sheetOffset(page: page, projection: projection, graphics: graphics)
        let entities = graphics.entities.map { $0.translated(by: offset) }
        var textBounds: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        func appendText(_ text: String, position: SIMD2<Double>, height: Double) {
            let width = bomTextAdvance(text, height: height)
            let min = SIMD2(position.x, position.y - height * 0.25)
            let max = SIMD2(position.x + width, position.y + height * 0.85)
            textBounds.append((min, max))
        }
        for text in graphics.texts {
            appendText(text.text, position: text.position + offset,
                       height: text.height)
        }
        // The sheet labels are not part of pageGraphics; include the two
        // free-standing ones so a top/above-text candidate cannot cover them.
        let geometry = bomSheetGeometry(page: page)
        if let viewID = page.explodedViewID,
           let view = loadAssemblyValue()?.explodedView(viewID) {
            appendText("Exploded: \(view.name)",
                       position: SIMD2(geometry.frameMin.x + 2,
                                       geometry.frameMax.y - 6),
                       height: 3.0)
        }
        if let revision = page.modelRevision {
            appendText("Rev \(revision)",
                       position: SIMD2(max(geometry.frameMin.x + 2,
                                           geometry.frameMax.x - 34),
                                       geometry.frameMax.y - 6),
                       height: 3.0)
        }
        // The first repair candidate clears the projected geometry. Text
        // bounds are checked by `bomTable`; a separate candidate clears the
        // highest text band if the geometry-only candidate hits one.
        let entityMaxY = entityBounds(entities)?.max.y ?? 0
        let maxY = max(0, entityMaxY)
        return BOMPlacementObstacles(
            entities: entities, textBounds: textBounds,
            titleBlockMin: geometry.titleBlockMin,
            titleBlockMax: geometry.titleBlockMax,
            maxY: maxY)
    }

    private func bomTable(_ layout: BOMTableLayout,
                          intersects obstacles: BOMPlacementObstacles) -> Bool {
        if bomRectsOverlap(layout.minPoint, layout.maxPoint,
                           obstacles.titleBlockMin, obstacles.titleBlockMax) {
            return true
        }
        for entity in obstacles.entities {
            if bomEntity(entity, intersects: layout.minPoint, layout.maxPoint) {
                return true
            }
        }
        for bounds in obstacles.textBounds {
            if bomRectsOverlap(layout.minPoint, layout.maxPoint,
                               bounds.min, bounds.max) {
                return true
            }
        }
        return false
    }

    private func bomRectsOverlap(_ aMin: SIMD2<Double>, _ aMax: SIMD2<Double>,
                                 _ bMin: SIMD2<Double>, _ bMax: SIMD2<Double>) -> Bool {
        aMin.x < bMax.x - 1e-6 && aMax.x > bMin.x + 1e-6
            && aMin.y < bMax.y - 1e-6 && aMax.y > bMin.y + 1e-6
    }

    private func bomEntity(_ entity: ProjectedEntity,
                           intersects rectMin: SIMD2<Double>,
                           _ rectMax: SIMD2<Double>) -> Bool {
        let rect = (min: rectMin, max: rectMax)
        switch entity.shape {
        case let .line(a, b):
            return clipSegment(a, b, rect: rect) != nil
        case let .circle(center, radius):
            let closest = SIMD2(Swift.min(Swift.max(center.x, rectMin.x), rectMax.x),
                                Swift.min(Swift.max(center.y, rectMin.y), rectMax.y))
            return simd_distance(closest, center) <= radius + 1e-9
        case let .arc(center, radius, _, _):
            let closest = SIMD2(Swift.min(Swift.max(center.x, rectMin.x), rectMax.x),
                                Swift.min(Swift.max(center.y, rectMin.y), rectMax.y))
            return simd_distance(closest, center) <= radius + 1e-9
        case let .polyline(points, _):
            guard points.count >= 2 else { return false }
            for index in 0..<(points.count - 1) {
                if clipSegment(points[index], points[index + 1], rect: rect) != nil {
                    return true
                }
            }
            return false
        }
    }

    private func bomHeaderDescriptors(_ layout: BOMTableLayout)
        -> [(text: String, x: Double, width: Double)] {
        let partHeader = layout.partWidth >= 18 ? "Part no." : "P/N"
        let materialHeader = layout.materialWidth >= 18 ? "Material" : "Mat."
        return [
            ("#", layout.itemX + 1, layout.itemWidth),
            ("Part", layout.nameX + 1, layout.nameWidth),
            ("Qty", layout.quantityX + 1, layout.quantityWidth),
            (partHeader, layout.partX + 1, layout.partWidth),
            (materialHeader, layout.materialX + 1, layout.materialWidth),
            ("Rev", layout.versionX + 1, layout.versionWidth),
        ]
    }

    /// Fit a vector cell to its real column width. The PDF renderer draws with
    /// `CTFontCreateWithName("Helvetica", height, nil)`, and CoreText supplies
    /// the same PingFang SC fallback for Chinese, so those are the metrics
    /// used here. The result is a whole-grapheme prefix plus one ellipsis
    /// (never a UTF-16 slice), or empty when even the ellipsis does not fit.
    private func bomFittedCell(_ text: String, availableWidth: Double,
                               height: Double) -> BOMCellFit {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !flattened.isEmpty else {
            return BOMCellFit(text: "", truncated: false)
        }
        let available = max(0.25, availableWidth)
        if bomTextAdvance(flattened, height: height) <= available + 1e-9 {
            return BOMCellFit(text: flattened, truncated: false)
        }
        let characters = Array(flattened)
        var low = 0
        var high = characters.count
        var best = -1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(characters.prefix(mid)) + "…"
            if bomTextAdvance(candidate, height: height) <= available + 1e-9 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard best >= 0 else {
            return BOMCellFit(text: "", truncated: true)
        }
        return BOMCellFit(text: String(characters.prefix(best)) + "…",
                          truncated: true)
    }

    private func bomTextAdvance(_ text: String, height: Double) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateWithName("Helvetica" as CFString, height, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func bomOutputStatus(page: CADDrawingPage, rowCount: Int,
                                 rows: [[String: Any]]? = nil,
                                 includePlacementStatus: Bool = true) -> [String: Any] {
        let layout = bomTableLayout(page: page, rowCount: rowCount,
                                    checkPlacement: includePlacementStatus)
        var output: [String: Any] = [
            "totalRows": rowCount,
            "capacity": layout.capacity,
            "vectorComplete": layout.complete,
            "requiredColumnsFit": layout.requiredColumnsFit,
            "tableZone": layout.tableZone,
            "fullTableFormat": "csv",
        ]
        if let rows {
            output["vectorTextComplete"] = !bomVectorTextTruncated(rows: rows,
                                                                   layout: layout)
        }
        if !layout.complete {
            output["previewRows"] = layout.visibleRows
            output["nextAction"] = Self.bomFullTableNextAction
        }
        return output
    }

    private func bomVectorTextTruncated(rows: [[String: Any]],
                                        layout: BOMTableLayout) -> Bool {
        let fields: [(String, Double)] = [
            ("name", layout.nameWidth - 2),
            ("partNumber", layout.partWidth - 2),
            ("material", layout.materialWidth - 2),
            ("version", layout.versionWidth - 2),
        ]
        for row in rows {
            for (key, width) in fields {
                let value = (row[key] as? String) ?? ""
                let fit = bomFittedCell(value, availableWidth: width, height: 2.8)
                if value.contains("\n") || value.contains("\r") || fit.truncated {
                    return true
                }
            }
            let item = row["itemNumber"] as? Int ?? 0
            if bomFittedCell("\(item)", availableWidth: layout.itemWidth - 2,
                             height: 2.8).truncated {
                return true
            }
            let quantity = row["quantity"] as? Int ?? 0
            if bomFittedCell("\(quantity)", availableWidth: layout.quantityWidth - 2,
                             height: 2.8).truncated {
                return true
            }
        }
        for header in bomHeaderDescriptors(layout) {
            if bomFittedCell(header.text, availableWidth: header.width - 2,
                             height: 2.8).truncated {
                return true
            }
        }
        return false
    }

    private func bomOutputIncomplete(rowCount: Int,
                                     layout: BOMTableLayout) -> CADDocumentError {
        let reason: String
        if !layout.zoneFits {
            reason = "no free sheet area can hold the table clear of the projected "
                + "drawing and title block"
        } else if !layout.requiredColumnsFit {
            reason = "the sheet is too narrow for the required item, name, part number, "
                + "material, revision and quantity columns"
        } else {
            reason = "the sheet can show at most \(layout.capacity) of \(rowCount) rows"
        }
        let message = "Vector BOM output is incomplete: \(reason). "
            + Self.bomFullTableNextAction
        return CADDocumentError(
            code: "bom_output_incomplete",
            message: message,
            details: [
                "actualRows": String(rowCount),
                "capacity": String(layout.capacity),
                "requiredColumns": "6",
                "requiredColumnsFit": layout.requiredColumnsFit ? "true" : "false",
                "tableZone": layout.tableZone,
                "zoneFits": layout.zoneFits ? "true" : "false",
                "fullTableFormat": "csv",
                "nextAction": Self.bomFullTableNextAction,
            ])
    }

    private static let bomFullTableNextAction =
        "Export the complete table as CSV with drawing.export format=csv "
        + "(cad.document export output=\"<name>.csv\" page_id=<page>)."

    private func rectangleEntities(min: SIMD2<Double>, max: SIMD2<Double>,
                                   layer: String) -> [ProjectedEntity] {
        [
            ProjectedEntity(shape: .line(SIMD2(min.x, min.y), SIMD2(max.x, min.y)),
                            layer: layer),
            ProjectedEntity(shape: .line(SIMD2(max.x, min.y), SIMD2(max.x, max.y)),
                            layer: layer),
            ProjectedEntity(shape: .line(SIMD2(max.x, max.y), SIMD2(min.x, max.y)),
                            layer: layer),
            ProjectedEntity(shape: .line(SIMD2(min.x, max.y), SIMD2(min.x, min.y)),
                            layer: layer),
        ]
    }

    // MARK: - PDF export

    private func pdfData(page: CADDrawingPage, graphics: RenderGraphics) throws -> Data {
        let paperWidth = max(page.paperWidthMM, 1)
        let paperHeight = max(page.paperHeightMM, 1)
        let pointsPerMillimetre = 72.0 / 25.4
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw CADDocumentError(code: "pdf_context",
                                   message: "Could not create a PDF data consumer.")
        }
        var mediaBox = CGRect(x: 0, y: 0,
                              width: paperWidth * pointsPerMillimetre,
                              height: paperHeight * pointsPerMillimetre)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CADDocumentError(code: "pdf_context",
                                   message: "Could not create a PDF context.")
        }
        context.beginPDFPage(nil)
        context.saveGState()
        context.scaleBy(x: pointsPerMillimetre, y: pointsPerMillimetre)
        drawPDF(graphics, in: context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func drawPDF(_ graphics: RenderGraphics, in context: CGContext,
                         minimumStrokeMM: Double = 0,
                         flipYPaperHeight: Double? = nil) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // Geometry y is drawing-space (y up). In a PDF context the CTM
        // already matches; in the y-down bitmap context used by the PNG
        // raster the same geometry is mirrored unless each y is mapped
        // through `paperHeight - y` (the SVG exporter's own approach).
        func geometryPoint(_ point: SIMD2<Double>) -> CGPoint {
            if let paperHeight = flipYPaperHeight {
                return CGPoint(x: point.x, y: paperHeight - point.y)
            }
            return CGPoint(x: point.x, y: point.y)
        }
        for entity in graphics.entities {
            let isCenterline = entity.layer == "centerline"
            context.setStrokeColor(gray: 0, alpha: 1)
            let baseWidth = graphics.lineWidthMM.isFinite && graphics.lineWidthMM > 0
                ? graphics.lineWidthMM : 0.25
            let width = isCenterline ? max(0.12, baseWidth * 0.72) : baseWidth
            context.setLineWidth(max(width, minimumStrokeMM))
            context.setLineDash(phase: 0, lengths: isCenterline ? [3, 1.5] : [])
            let path = CGMutablePath()
            switch entity.shape {
            case let .line(a, b):
                path.move(to: geometryPoint(a))
                path.addLine(to: geometryPoint(b))
            case let .circle(center, radius):
                let mapped = geometryPoint(center)
                path.addEllipse(in: CGRect(x: mapped.x - radius, y: mapped.y - radius,
                                           width: radius * 2, height: radius * 2))
            case let .arc(center, radius, startAngle, endAngle):
                // A mirrored arc reverses its sweep: negate the angles so the
                // ink covers the same drawing arc.
                let mapped = geometryPoint(center)
                let start = flipYPaperHeight == nil ? startAngle : -endAngle
                let end = flipYPaperHeight == nil ? endAngle : -startAngle
                path.addArc(center: mapped, radius: radius,
                            startAngle: start, endAngle: end, clockwise: false)
            case let .polyline(points, closed):
                guard let first = points.first else { continue }
                path.move(to: geometryPoint(first))
                for point in points.dropFirst() {
                    path.addLine(to: geometryPoint(point))
                }
                if closed { path.closeSubpath() }
            }
            context.addPath(path)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        for text in graphics.texts {
            drawPDFText(text, in: context, flipYPaperHeight: flipYPaperHeight)
        }
    }

    private func drawPDFText(_ text: DrawingText, in context: CGContext,
                             flipYPaperHeight: Double? = nil) {
        guard !text.text.isEmpty else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, text.height, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text.text as CFString, attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        guard let paperHeight = flipYPaperHeight else {
            // PDF path: the text system already shares the drawing space.
            context.textPosition = CGPoint(x: text.position.x, y: text.position.y)
            CTLineDraw(line, context)
            return
        }
        // y-down raster: map the anchor and draw the line where the text
        // system's own y-up convention renders it upright (verified
        // empirically on this platform).
        context.textPosition = CGPoint(x: text.position.x, y: paperHeight - text.position.y)
        CTLineDraw(line, context)
    }

    // MARK: - PNG rasterization (Canvas asset)

    /// Offscreen white-background PNG of the exact same projected vector
    /// drawing the PDF export draws. The page's millimetre box is fit into
    /// `targetSize` (default 1024pt on the long edge); text is drawn through
    /// the same CoreText path so the raster and the PDF never diverge.
    static let defaultPNGLongEdge: Double = 1024

    private func pngData(page: CADDrawingPage, graphics: RenderGraphics,
                         targetSize: Double = CADDrawingService.defaultPNGLongEdge) throws -> Data {
        let paperWidth = max(page.paperWidthMM, 1)
        let paperHeight = max(page.paperHeightMM, 1)
        let longEdge = max(targetSize, 64)
        let scale = longEdge / max(paperWidth, paperHeight)
        let pixelWidth = max(1, Int((paperWidth * scale).rounded()))
        let pixelHeight = max(1, Int((paperHeight * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw CADDocumentError(code: "png_context",
                                   message: "Could not create the PNG bitmap context.")
        }
        // White sheet first.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // A bitmap CGContext is y-down (origin top-left) while drawing
        // coordinates are y-up in millimetres. Unlike the PDF context, no CTM
        // flip is applied here: the context is scaled to pixels and `drawPDF`
        // maps every drawing y through `paperHeight - y` (the same idiom the
        // SVG exporter uses point-by-point), which keeps glyphs upright.
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // A hairline that is exact in PDF antialiases to a near-invisible
        // 0.6px grey at typical paper sizes. The raster raises the stroke
        // floor to ~1.5px so the Canvas asset stays legible; PDF/SVG keep
        // their exact drawing widths (the R12 DXF entity set has no lineweight
        // attribute, so it carries the geometry/text, not the style width).
        drawPDF(graphics, in: context, minimumStrokeMM: 1.5 / scale,
                flipYPaperHeight: paperHeight)
        guard let image = context.makeImage() else {
            throw CADDocumentError(code: "png_render",
                                   message: "The drawing bitmap could not be rendered.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CADDocumentError(code: "png_encode",
                                   message: "The PNG encoder could not be created.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CADDocumentError(code: "png_encode",
                                   message: "The drawing PNG could not be encoded.")
        }
        return data as Data
    }

    // MARK: - SVG export

    private func svgData(page: CADDrawingPage, graphics: RenderGraphics) -> Data {
        let width = max(page.paperWidthMM, 1)
        let height = max(page.paperHeightMM, 1)
        func flipped(_ value: Double) -> Double { height - value }
        func number(_ value: Double) -> String { String(format: "%.4f", value) }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\""
        out += " width=\"\(number(width))mm\" height=\"\(number(height))mm\""
        out += " viewBox=\"0 0 \(number(width)) \(number(height))\">\n"
        let layerOrder = ["outline", "edges", "geometry", "section", "dimension",
                          "centerline", "annotation", "balloon", "bom", "title"]
        // All model/annotation layers merge into ONE SVG group per named layer
        // (GEOMETRY/DIMENSIONS/CENTERLINES/TITLE) so a document never emits
        // duplicate ids and every shape — including projected circles — is
        // reachable inside its group.
        var groupedEntities: [String: [ProjectedEntity]] = [:]
        var groupedTexts: [String: [DrawingText]] = [:]
        for layer in layerOrder {
            let name = svgLayerName(layer)
            groupedEntities[name, default: []].append(contentsOf: graphics.entities.filter { $0.layer == layer })
            groupedTexts[name, default: []].append(contentsOf: graphics.texts.filter { $0.layer == layer })
        }
        for groupName in ["GEOMETRY", "DIMENSIONS", "CENTERLINES", "ANNOTATIONS", "BOM", "TITLE"] {
            let entities = groupedEntities[groupName] ?? []
            let texts = groupedTexts[groupName] ?? []
            guard !entities.isEmpty || !texts.isEmpty else { continue }
            if !entities.isEmpty {
                let strokeWidth = abs(graphics.lineWidthMM - 0.25) < 1e-9
                    ? "0.25" : number(graphics.lineWidthMM)
                out += "<g id=\"\(groupName)\" fill=\"none\" stroke=\"#000000\""
                out += " stroke-width=\"\(strokeWidth)\">\n"
                for entity in entities {
                    switch entity.shape {
                    case let .line(a, b):
                        out += "<line x1=\"\(number(a.x))\" y1=\"\(number(flipped(a.y)))\""
                        out += " x2=\"\(number(b.x))\" y2=\"\(number(flipped(b.y)))\"/>\n"
                    case let .circle(center, radius):
                        out += "<circle cx=\"\(number(center.x))\""
                        out += " cy=\"\(number(flipped(center.y)))\""
                        out += " r=\"\(number(radius))\"/>\n"
                    case let .arc(center, radius, startAngle, endAngle):
                        let points = SketchEntity.arcPoints(
                            center: center, radius: radius, startAngle: startAngle,
                            endAngle: endAngle, segmentsPerTurn: 64)
                        if let path = svgPath(points, closed: false, flip: flipped,
                                              number: number) {
                            out += path
                        }
                    case let .polyline(points, closed):
                        if let path = svgPath(points, closed: closed, flip: flipped,
                                              number: number) {
                            out += path
                        }
                    }
                }
                out += "</g>\n"
            }
            if !texts.isEmpty {
                out += "<g id=\"\(groupName)_TEXT\""
                out += " font-family=\"Helvetica, Arial, sans-serif\""
                out += " font-size=\"3\" fill=\"#000000\">\n"
                for text in texts {
                    out += "<text x=\"\(number(text.position.x))\""
                    out += " y=\"\(number(flipped(text.position.y)))\""
                    out += " font-size=\"\(number(text.height))\">"
                    out += "\(escapeXML(text.text))</text>\n"
                }
                out += "</g>\n"
            }
        }
        out += "</svg>\n"
        return Data(out.utf8)
    }

    private func svgPath(_ points: [SIMD2<Double>], closed: Bool,
                         flip: (Double) -> Double,
                         number: (Double) -> String) -> String? {
        guard let first = points.first, points.count >= 2 else { return nil }
        var d = "M \(number(first.x)) \(number(flip(first.y)))"
        for point in points.dropFirst() {
            d += " L \(number(point.x)) \(number(flip(point.y)))"
        }
        if closed { d += " Z" }
        return "<path d=\"\(d)\"/>\n"
    }

    // MARK: - DXF export

    private func dxfData(page: CADDrawingPage, graphics: RenderGraphics) -> Data {
        var out = "999\nFloeCAD drawing export (units: mm)\n"
        out += "0\nSECTION\n2\nHEADER\n"
        out += "9\n$ACADVER\n1\nAC1009\n"
        // R2004 and prior are ASCII files: $DWGCODEPAGE names the single-byte
        // codepage (ANSI_1252 default) and characters outside it use the
        // `\U+nnnn` schema. The writer emits pure ASCII; declaring the
        // codepage keeps the truthful R12 contract explicit instead of
        // relying on UTF-8 autodetection, which no AC1009 reader promises.
        out += "9\n$DWGCODEPAGE\n3\nANSI_1252\n"
        out += "9\n$INSUNITS\n70\n4\n"
        out += "9\n$MEASUREMENT\n70\n1\n"
        out += "0\nENDSEC\n"
        out += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n6\n"
        for layer in ["GEOMETRY", "DIMENSIONS", "CENTERLINES", "ANNOTATIONS", "BOM", "TITLE"] {
            out += "0\nLAYER\n2\n\(layer)\n70\n0\n62\n7\n6\nCONTINUOUS\n"
        }
        out += "0\nENDTAB\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nENTITIES\n"
        for entity in graphics.entities {
            let layer = dxfLayer(entity.layer)
            switch entity.shape {
            case let .line(a, b):
                out += "0\nLINE\n8\n\(layer)\n"
                out += dxfPair(10, 20, a) + dxfCode(30, 0)
                out += dxfPair(11, 21, b) + dxfCode(31, 0)
            case let .circle(center, radius):
                out += "0\nCIRCLE\n8\n\(layer)\n"
                out += dxfPair(10, 20, center) + dxfCode(30, 0) + dxfCode(40, radius)
            case let .arc(center, radius, startAngle, endAngle):
                out += "0\nARC\n8\n\(layer)\n"
                out += dxfPair(10, 20, center) + dxfCode(30, 0) + dxfCode(40, radius)
                out += dxfCode(50, startAngle * 180 / Double.pi)
                out += dxfCode(51, endAngle * 180 / Double.pi)
            case let .polyline(points, closed):
                guard points.count >= 2 else { continue }
                out += "0\nPOLYLINE\n8\n\(layer)\n66\n1\n70\n\(closed ? 1 : 0)\n"
                for point in points {
                    out += "0\nVERTEX\n8\n\(layer)\n"
                    out += dxfPair(10, 20, point) + dxfCode(30, 0)
                }
                out += "0\nSEQEND\n8\n\(layer)\n"
            }
        }
        for text in graphics.texts {
            out += "0\nTEXT\n8\n\(dxfLayer(text.layer))\n"
            out += dxfPair(10, 20, text.position) + dxfCode(30, 0)
            out += dxfCode(40, text.height)
            out += "1\n\(sanitizedDXFText(text.text))\n"
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return Data(out.utf8)
    }

    private func dxfCode(_ groupCode: Int, _ value: Double) -> String {
        "\(groupCode)\n\(String(format: "%.9f", value))\n"
    }

    private func dxfPair(_ xCode: Int, _ yCode: Int, _ point: SIMD2<Double>) -> String {
        dxfCode(xCode, point.x) + dxfCode(yCode, point.y)
    }

    private func dxfLayer(_ layer: String) -> String {
        switch layer {
        case "dimension": return "DIMENSIONS"
        case "centerline": return "CENTERLINES"
        case "annotation", "balloon": return "ANNOTATIONS"
        case "bom": return "BOM"
        case "title": return "TITLE"
        default: return "GEOMETRY"
        }
    }

    private func svgLayerName(_ layer: String) -> String {
        switch layer {
        case "dimension": return "DIMENSIONS"
        case "centerline": return "CENTERLINES"
        case "annotation", "balloon": return "ANNOTATIONS"
        case "bom": return "BOM"
        case "title": return "TITLE"
        default: return "GEOMETRY"
        }
    }

    private func sanitizedDXFText(_ text: String) -> String {
        // One TEXT tag is one line. Every remaining scalar then goes through
        // the isolated R12 codec: printable ASCII stays literal and everything
        // else is a `\U+nnnn` escape, so the entity bytes remain ASCII and a
        // real DXF reader decodes the author's Chinese and engineering
        // symbols (Ø, ×, –, ·) instead of mojibake. The codec also escapes a
        // literal `\U+0041`-style author backslash once, so it survives a
        // single decode pass unchanged.
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return DXFTextCodec.encode(singleLine)
    }

    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Geometry helpers

    private func entityBounds(_ entities: [ProjectedEntity])
        -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        var low: SIMD2<Double>?
        var high: SIMD2<Double>?
        func include(_ point: SIMD2<Double>) {
            guard point.x.isFinite, point.y.isFinite else { return }
            if let currentLow = low, let currentHigh = high {
                low = simd_min(currentLow, point)
                high = simd_max(currentHigh, point)
            } else {
                low = point
                high = point
            }
        }
        for entity in entities {
            switch entity.shape {
            case let .line(a, b):
                include(a)
                include(b)
            case let .circle(center, radius):
                include(SIMD2(center.x - radius, center.y - radius))
                include(SIMD2(center.x + radius, center.y + radius))
            case let .arc(center, radius, _, _):
                include(SIMD2(center.x - radius, center.y - radius))
                include(SIMD2(center.x + radius, center.y + radius))
            case let .polyline(points, _):
                for point in points { include(point) }
            }
        }
        guard let resolvedLow = low, let resolvedHigh = high else { return nil }
        return (resolvedLow, resolvedHigh)
    }

    private func clipped(_ entity: ProjectedEntity,
                         to rect: (min: SIMD2<Double>, max: SIMD2<Double>))
        -> [ProjectedEntity] {
        switch entity.shape {
        case let .line(a, b):
            guard let (c, d) = clipSegment(a, b, rect: rect) else { return [] }
            return [ProjectedEntity(shape: .line(c, d), layer: entity.layer)]
        case let .circle(center, _):
            return contains(rect, center) ? [entity] : []
        case let .arc(center, _, _, _):
            return contains(rect, center) ? [entity] : []
        case let .polyline(points, _):
            guard points.count >= 2 else { return [] }
            var pieces: [ProjectedEntity] = []
            for index in 0..<(points.count - 1) {
                if let (c, d) = clipSegment(points[index], points[index + 1], rect: rect) {
                    pieces.append(ProjectedEntity(shape: .line(c, d), layer: entity.layer))
                }
            }
            return pieces
        }
    }

    private func contains(_ rect: (min: SIMD2<Double>, max: SIMD2<Double>),
                          _ point: SIMD2<Double>) -> Bool {
        point.x >= rect.min.x - 1e-9 && point.x <= rect.max.x + 1e-9
            && point.y >= rect.min.y - 1e-9 && point.y <= rect.max.y + 1e-9
    }

    /// Liang–Barsky segment/rectangle clip; nil when nothing remains.
    private func clipSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                             rect: (min: SIMD2<Double>, max: SIMD2<Double>))
        -> (SIMD2<Double>, SIMD2<Double>)? {
        var t0 = 0.0
        var t1 = 1.0
        let delta = b - a
        let p = [-delta.x, delta.x, -delta.y, delta.y]
        let q = [a.x - rect.min.x, rect.max.x - a.x,
                 a.y - rect.min.y, rect.max.y - a.y]
        for index in 0..<4 {
            if abs(p[index]) < 1e-12 {
                if q[index] < 0 { return nil }
                continue
            }
            let ratio = q[index] / p[index]
            if p[index] < 0 {
                t0 = max(t0, ratio)
            } else {
                t1 = min(t1, ratio)
            }
        }
        guard t0 <= t1 else { return nil }
        return (a + delta * t0, a + delta * t1)
    }

    private func bodyLocal(_ world: SIMD3<Double>, _ transform: Transform3D) -> SIMD3<Double> {
        let unscaled = transform.rotation.inverse.act(world - transform.translation)
        let scale = transform.scale
        return abs(scale) > 1e-12 ? unscaled / scale : unscaled
    }

    private func normalizeDirection(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let length = simd_length(vector)
        return length > 1e-12 ? vector / length : SIMD3<Double>(0, 0, 1)
    }

    // MARK: - Formatting

    private func formatLength(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e12 else { return "-" }
        let rounded = (value * 10_000).rounded() / 10_000
        if abs(rounded - rounded.rounded()) < 1e-9 {
            return String(Int(rounded.rounded()))
        }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func scaleText(_ scale: Double) -> String {
        guard scale.isFinite, scale > 0 else { return "SCALE -" }
        if abs(scale - 1) < 1e-9 { return "SCALE 1:1" }
        if scale < 1 { return "SCALE 1:\(formatLength(1 / scale))" }
        return "SCALE \(formatLength(scale)):1"
    }

    // MARK: - Persistence

    private func loadSet() -> Result<CADDrawingSet, CADDrawingServiceError> {
        do {
            return .success(try CADDrawingSet.decode(from: document.session.document.drawingsData))
        } catch {
            return .failure(CADDrawingServiceError(
                code: "corrupt_drawings",
                message: "The stored drawing set JSON could not be read; it was left untouched."))
        }
    }

    /// Writes the drawing set as ONE undoable command on the document, so a
    /// drawing edit shares the undo stack and can be composed atomically with
    /// geometry commands (and `save()` mirrors it into the package). A set
    /// written by a NEWER schema is refused rather than downgraded.
    private func persist(_ set: CADDrawingSet, projectionCacheOnly: Bool = false) -> [String: Any]? {
        guard set.schemaVersion <= CADDrawingSet.currentSchemaVersion else {
            return fail("unsupported_version",
                        "The drawing set uses schema v\(set.schemaVersion), newer than this build "
                        + "(v\(CADDrawingSet.currentSchemaVersion)); edits are refused.")
        }
        var updated = set
        // v4 is additive: old v1/v2/v3 pages decoded with defaults, but the
        // first write this build produces is honestly stamped v4 so an older
        // reader cannot silently drop shared-sheet views or linked-dimension
        // identity on a later edit.
        updated.schemaVersion = CADDrawingSet.currentSchemaVersion
        do {
            let data = try updated.encoded()
            if projectionCacheOnly {
                document.session.refreshDrawingProjectionData(data)
            } else {
                document.session.perform(SetDrawingsDataCommand(
                    before: document.session.document.drawingsData, after: data))
            }
            return nil
        } catch {
            return fail("encode_failed",
                        "The drawing set could not be encoded: \(error.localizedDescription)")
        }
    }

    private func body(for id: UUID) -> Body? {
        document.session.document.bodies.first { $0.id.raw == id }
    }

    private func loadAssemblyValue() -> CADAssembly? {
        guard let data = document.session.document.assemblyData else { return nil }
        return try? CADAssembly.decode(from: data)
    }

    private func effectiveBodyID(_ instance: CADAssemblyInstance) -> UUID {
        instance.copiedBodyID ?? instance.bodyID
    }

    private func pageIsAssemblyAware(_ page: CADDrawingPage) -> Bool {
        page.assemblyMode || page.kind == .exploded || page.explodedViewID != nil
    }

    /// A persisted page can outlive the named view it references. That is a
    /// visible binding error, never a silent switch to the base placement for
    /// output.
    private func pageMissingExplodedView(_ page: CADDrawingPage) -> Bool {
        guard let id = page.explodedViewID else { return false }
        return loadAssemblyValue()?.explodedView(id) == nil
    }

    /// True when a section view on this page would omit a source (mesh-only,
    /// missing body or missing instance). Vector export must be blocked rather
    /// than presenting the partial section as a complete drawing.
    private func pageSectionIncomplete(_ page: CADDrawingPage) -> Bool {
        for view in page.effectiveSheetViews where view.kind == .section {
            if view.sectionOrigin == nil || view.sectionNormal == nil { return true }
            if !view.scale.isFinite || view.scale <= 0 { return true }
            let resolved = projectionSources(for: page, sourceBodyIDs: view.sourceBodyIDs)
            if !resolved.missingBodies.isEmpty || !resolved.missingInstances.isEmpty {
                return true
            }
            if resolved.sources.contains(where: { $0.body.brep == nil }) {
                return true
            }
            if resolved.sources.isEmpty {
                return true
            }
        }
        return false
    }

    /// Informational revision for the status line: the max `meshRevision`
    /// over resolvable sources. NOT the staleness authority (see
    /// `liveFingerprint`).
    private func maxMeshRevision(for page: CADDrawingPage) -> UInt64? {
        var revision: UInt64?
        let pageSourceIDs = page.effectiveSourceBodyIDs
        if pageIsAssemblyAware(page) {
            let filter = Set(pageSourceIDs)
            // Traverse the SAME nested occurrences the projection and BOM use;
            // looking only at top-level instances skips every leaf under a
            // subassembly and would leave a nested sheet without a revision.
            for occurrence in loadAssemblyValue()?.occurrences(includeHidden: false) ?? []
            where occurrence.isDrawablePart {
                guard let id = occurrence.effectiveBodyID,
                      filter.isEmpty || filter.contains(id),
                      let source = body(for: id) else { continue }
                revision = max(revision ?? 0, source.meshRevision)
            }
            return revision
        }
        for id in pageSourceIDs {
            guard let body = body(for: id) else { continue }
            revision = max(revision ?? 0, body.meshRevision)
        }
        return revision
    }

    /// Ordered per-source identity of the page's live geometry. Ordinary
    /// pages keep one entry per `sourceBodyIDs` entry (order preserved).
    /// Assembly-aware pages add one `InstanceSource` per visible placed
    /// instance with the hash of its world placement INCLUDING the exploded
    /// offset, so switching a view (or moving an instance) marks the page
    /// stale even when the source mesh is unchanged.
    private func liveFingerprint(for page: CADDrawingPage) -> CADDrawingSourceFingerprint {
        let pageSourceIDs = page.effectiveSourceBodyIDs
        guard pageIsAssemblyAware(page) else {
            return CADDrawingSourceFingerprint(sources: pageSourceIDs.map { id in
                guard let body = body(for: id) else {
                    return CADDrawingSourceFingerprint.Source(bodyID: id, missing: true)
                }
                return CADDrawingSourceFingerprint.Source(
                    bodyID: id,
                    missing: false,
                    renderSHA256: CADScriptService.renderHash(body.render),
                    placementSHA256: Self.transformHash(body.transform))
            })
        }
        let assembly = loadAssemblyValue()
        let view = page.explodedViewID.flatMap { assembly?.explodedView($0) }
        let filter = Set(pageSourceIDs)
        var instances = (assembly?.instances ?? []).filter { !$0.isHidden }
        if !filter.isEmpty {
            instances = instances.filter { filter.contains(effectiveBodyID($0)) }
        }
        if instances.count > 64 { instances = Array(instances.prefix(64)) }

        var sourceIDs: [UUID] = []
        var seen = Set<UUID>()
        if pageSourceIDs.isEmpty {
            for instance in instances {
                let id = effectiveBodyID(instance)
                if seen.insert(id).inserted { sourceIDs.append(id) }
            }
        } else {
            sourceIDs = pageSourceIDs
        }
        let sources = sourceIDs.map { id -> CADDrawingSourceFingerprint.Source in
            guard let body = body(for: id) else {
                return CADDrawingSourceFingerprint.Source(bodyID: id, missing: true)
            }
            return CADDrawingSourceFingerprint.Source(
                bodyID: id,
                missing: false,
                renderSHA256: CADScriptService.renderHash(body.render),
                placementSHA256: Self.transformHash(body.transform))
        }
        let instanceSources = instances.map { instance -> CADDrawingSourceFingerprint.InstanceSource in
            let id = effectiveBodyID(instance)
            guard let source = body(for: id),
                  instance.transform.isPlaceable else {
                return CADDrawingSourceFingerprint.InstanceSource(
                    instanceID: instance.id, bodyID: id, missing: true,
                    explodedViewID: view?.id)
            }
            var world = instance.transform.placement3D().composed(onto: source.transform)
            if let view {
                let offset = view.offset(for: instance.id)
                if offset != .zero {
                    world = Transform3D(translation: offset).composed(onto: world)
                }
            }
            return CADDrawingSourceFingerprint.InstanceSource(
                instanceID: instance.id, bodyID: id, missing: false,
                placementSHA256: Self.transformHash(world),
                explodedViewID: view?.id)
        }
        return CADDrawingSourceFingerprint(sources: sources, instances: instanceSources)
    }

    /// Deterministic placement hash: the numeric TRS components, not a JSON
    /// encoding (whose dictionary ordering must never be an identity input).
    private static func transformHash(_ transform: Transform3D) -> String? {
        var values: [Double] = [
            transform.translation.x, transform.translation.y, transform.translation.z,
            transform.rotation.vector.x, transform.rotation.vector.y,
            transform.rotation.vector.z, transform.rotation.vector.w,
            transform.scale,
        ]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - JSON / argument helpers

    private func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }

    private func vectorPayload(_ vector: SIMD3<Double>) -> [Double] {
        [vector.x, vector.y, vector.z]
    }

    private func pointPayload(_ point: SIMD2<Double>) -> [Double] {
        [point.x, point.y]
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

    private func vector3(_ raw: Any?) -> SIMD3<Double>? {
        guard let values = doubleArray(raw), values.count == 3,
              values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private func doubleArray(_ raw: Any?) -> [Double]? {
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

    private func sizeValue(_ raw: Any?) -> (width: Double, height: Double)? {
        if let values = doubleArray(raw), values.count == 2,
           values.allSatisfy({ $0.isFinite && $0 > 0 }) {
            return (values[0], values[1])
        }
        if let single = doubleValue(raw), single.isFinite, single > 0 {
            return (single, single)
        }
        return nil
    }
}

// MARK: - File-private value types

/// One deterministic sheet-space placement for the complete BOM table.
/// `capacity` counts data rows (the header is extra); `totalRows` includes the
/// header and, for an incomplete preview, one explicit continuation row.
/// `zoneFits` is false only when a complete table has no free sheet area clear
/// of projected content and the title block.
private nonisolated struct BOMTableLayout {
    let tableWidth: Double
    let rowHeight: Double
    let minPoint: SIMD2<Double>
    let maxPoint: SIMD2<Double>
    let itemWidth: Double
    let nameWidth: Double
    let partWidth: Double
    let materialWidth: Double
    let versionWidth: Double
    let quantityWidth: Double
    let itemX: Double
    let nameX: Double
    let partX: Double
    let materialX: Double
    let versionX: Double
    let quantityX: Double
    let capacity: Int
    let requiredColumnsFit: Bool
    let complete: Bool
    let visibleRows: Int
    let totalRows: Int
    let placedAboveTitleBlock: Bool
    var tableZone: String = "bottomLeft"
    /// False only when a complete table has no free sheet zone clear of the
    /// projected drawing and title block.
    var zoneFits: Bool = true
}

private nonisolated struct BOMCellFit {
    let text: String
    let truncated: Bool
}

private nonisolated struct BOMSheetGeometry {
    let frameMin: SIMD2<Double>
    let frameMax: SIMD2<Double>
    let titleBlockWidth: Double
    let titleBlockMin: SIMD2<Double>
    let titleBlockMax: SIMD2<Double>
}

private nonisolated struct BOMPlacementObstacles {
    let entities: [ProjectedEntity]
    let textBounds: [(min: SIMD2<Double>, max: SIMD2<Double>)]
    let titleBlockMin: SIMD2<Double>
    let titleBlockMax: SIMD2<Double>
    let maxY: Double
}

private nonisolated struct CADDrawingServiceError: Error {
    let code: String
    let message: String
}

private nonisolated struct ProjectedEntity {
    nonisolated enum Shape {
        case line(SIMD2<Double>, SIMD2<Double>)
        case circle(center: SIMD2<Double>, radius: Double)
        case arc(center: SIMD2<Double>, radius: Double,
                 startAngle: Double, endAngle: Double)
        case polyline(points: [SIMD2<Double>], closed: Bool)
    }

    var shape: Shape
    var layer: String
    var area: Double?

    init(shape: Shape, layer: String, area: Double? = nil) {
        self.shape = shape
        self.layer = layer
        self.area = area
    }

    var kindName: String {
        switch shape {
        case .line: return "line"
        case .circle: return "circle"
        case .arc: return "arc"
        case .polyline: return "polyline"
        }
    }

    func scaled(by scale: Double) -> ProjectedEntity {
        guard scale != 1 else { return self }
        switch shape {
        case let .line(a, b):
            return ProjectedEntity(shape: .line(a * scale, b * scale), layer: layer)
        case let .circle(center, radius):
            return ProjectedEntity(shape: .circle(center: center * scale,
                                                  radius: radius * scale),
                                   layer: layer)
        case let .arc(center, radius, startAngle, endAngle):
            return ProjectedEntity(shape: .arc(center: center * scale,
                                               radius: radius * scale,
                                               startAngle: startAngle,
                                               endAngle: endAngle),
                                   layer: layer)
        case let .polyline(points, closed):
            return ProjectedEntity(shape: .polyline(points: points.map { $0 * scale },
                                                    closed: closed),
                                   layer: layer,
                                   area: area.map { $0 * scale * scale })
        }
    }

    func translated(by offset: SIMD2<Double>) -> ProjectedEntity {
        switch shape {
        case let .line(a, b):
            return ProjectedEntity(shape: .line(a + offset, b + offset), layer: layer)
        case let .circle(center, radius):
            return ProjectedEntity(shape: .circle(center: center + offset, radius: radius),
                                   layer: layer)
        case let .arc(center, radius, startAngle, endAngle):
            return ProjectedEntity(shape: .arc(center: center + offset, radius: radius,
                                               startAngle: startAngle,
                                               endAngle: endAngle),
                                   layer: layer)
        case let .polyline(points, closed):
            return ProjectedEntity(shape: .polyline(points: points.map { $0 + offset },
                                                    closed: closed),
                                   layer: layer, area: area)
        }
    }
}

private nonisolated struct PageProjection {
    var entities: [ProjectedEntity] = []
    var notes: [String] = []
    var missing: [UUID] = []
    var missingInstances: [UUID] = []
    var instances: [ProjectedInstance] = []
    var explodedViewID: UUID?
    var explodedViewName: String?
    /// Populated for a v4 shared sheet (one entry per view); legacy pages
    /// keep it empty so their payload stays unchanged.
    var views: [CADDrawingViewProjection] = []
    var viewIssues: [String] = []
    var sectionCoverage: [CADDrawingSectionCoverage] = []
    var sectionIncomplete: Bool = false
    var sectionComplete: Bool {
        get { !sectionIncomplete }
        set { sectionIncomplete = !newValue }
    }
    var outputBlocked: Bool = false
}

private nonisolated struct CADDrawingViewProjection {
    var view: CADDrawingSheetView
    var offset: SIMD2<Double> = .zero
    var entities: [ProjectedEntity] = []
    var instances: [ProjectedInstance] = []
    var notes: [String] = []
    var missing: [UUID] = []
    var missingInstances: [UUID] = []
    var sectionCoverage: [CADDrawingSectionCoverage] = []
    var sectionComplete: Bool = true
    var localBounds: (min: SIMD2<Double>, max: SIMD2<Double>)?
    var bounds: (min: SIMD2<Double>, max: SIMD2<Double>)?
}

private nonisolated struct CADDrawingSectionCoverage {
    var bodyID: UUID
    var instanceID: UUID?
    var name: String
    var analyticBRep: Bool
    var included: Bool
}

/// One geometry source for projection: a plain body (instanceID nil) or one
/// placed assembly instance. `body` already carries the world transform.
private nonisolated struct ProjectionSource {
    var instanceID: UUID?
    var name: String
    var body: Body
}

private nonisolated struct ProjectedInstance {
    var id: UUID
    var name: String
    var entities: [ProjectedEntity]
}

private nonisolated struct ResolvedProjectionSources {
    var sources: [ProjectionSource] = []
    var missingBodies: [UUID] = []
    var missingInstances: [UUID] = []
    var notes: [String] = []
    var explodedViewID: UUID?
    var explodedViewName: String?
}

private nonisolated struct DrawingDimension {
    var kind: String
    var axis: String?
    var value: Double
    var unit = "mm"
    var text: String
    var textPosition: SIMD2<Double>
    var center: SIMD2<Double>?
    var radius: Double?
    var leader: (SIMD2<Double>, SIMD2<Double>)?
    var extensionLines: [(SIMD2<Double>, SIMD2<Double>)]
    var dimensionLine: (SIMD2<Double>, SIMD2<Double>)?
}

private nonisolated struct DrawingText {
    var text: String
    var position: SIMD2<Double>
    var height: Double
    var layer: String
}

private nonisolated struct RenderGraphics {
    var entities: [ProjectedEntity]
    var texts: [DrawingText]
    /// Exact exported line width (mm). A template style can change it; the
    /// legacy default keeps every existing drawing byte-equivalent.
    var lineWidthMM: Double = 0.25
}

private nonisolated struct DetectedCircle {
    var center: SIMD2<Double>
    var radius: Double
    var isFull: Bool
}

private nonisolated struct FittedCircle {
    var center: SIMD2<Double>
    var radius: Double
    var maxResidual: Double
}

private nonisolated struct NodeKey: Hashable {
    let x: Int64
    let y: Int64
}
