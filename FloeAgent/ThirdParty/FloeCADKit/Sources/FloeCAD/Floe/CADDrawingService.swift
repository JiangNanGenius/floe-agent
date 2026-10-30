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
//    dimensions and text annotations. Every v3 field decodes to a default, so
//    v1/v2 pages load unchanged. Ordinary pages keep projecting raw body
//    transforms; only pages that ask for assembly mode project placed
//    instances (shared bodies and independent copies) with their exploded
//    view offsets. Paper/scale/title remain page data in both modes.
//  * Export layers: GEOMETRY (outline/edges/section), DIMENSIONS,
//    CENTERLINES, ANNOTATIONS (manual dimensions/balloons/text), BOM (sheet
//    table) and TITLE (sheet frame + title block + text). DXF is R12 ASCII,
//    `$INSUNITS` = 4 (mm), with a real LAYER table and TEXT entities.
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

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    // MARK: - Action router

    /// One JSON-shaped action. Expected errors come back as
    /// `["ok": false, "error": code, "message": text]`; mutating actions set
    /// `"mutated": true` so the caller persists with `document.save()`.
    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        switch action {
        case "pages": return pagesAction()
        case "addPage": return addPageAction(args)
        case "updatePage": return updatePageAction(args)
        case "removePage": return removePageAction(args)
        case "standardSheet": return standardSheetAction(args)
        case "project": return projectAction(args)
        case "dimensions": return dimensionsAction(args)
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
        default:
            return fail("unknown_action", "Unknown drawing action '\(action)'.")
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

    /// Real 2D vector export bytes. `format` is "pdf", "svg", "dxf" or "png".
    /// PNG is the one raster format: it is the same projected vector geometry
    /// drawn into a white CoreGraphics bitmap (never a viewport screenshot),
    /// intended for Canvas node assets.
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
        let projection = projectPage(page)
        let graphics = renderGraphics(page: page, projection: projection)
        switch format.lowercased() {
        case "pdf": return try pdfData(page: page, graphics: graphics)
        case "svg": return svgData(page: page, graphics: graphics)
        case "dxf": return dxfData(page: page, graphics: graphics)
        case "png": return try pngData(page: page, graphics: graphics)
        default:
            throw CADDocumentError(code: "unknown_format",
                                   message: "format must be pdf, svg, dxf or png.")
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
        let hasGeometry = !page.sourceBodyIDs.isEmpty
            || !(live.instances ?? []).isEmpty
        if live.sources.allSatisfy({ !$0.missing }), hasGeometry {
            let revision = maxMeshRevision(for: page)
            if page.sourceFingerprint != live || page.modelRevision != revision {
                page.sourceFingerprint = live
                page.modelRevision = revision
                updated.pages[index] = page
                if let failure = persist(updated) { return failure }
                mutated = true
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

    // MARK: - Export action

    private func exportAction(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuidValue(args["pageID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_page_id", "pageID must be a drawing page UUID string.")
        }
        guard let format = (args["format"] as? String)?.lowercased() else {
            return fail("missing_format", "format must be pdf, svg or dxf.")
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
            return fail(error.code, error.message)
        } catch {
            return fail("export_failed",
                        "The \(format) export failed: \(error.localizedDescription)")
        }
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
        guard let assembly = loadAssemblyValue(), !assembly.instances.isEmpty else {
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
                if let rawIDs = raw["instanceIDs"] as? [String] {
                    for text in rawIDs {
                        guard let instanceID = UUID(uuidString: text),
                              let instance = assembly?.instance(instanceID) else {
                            return fail("unknown_instance",
                                        "BOM entry instanceIDs must reference live instances.")
                        }
                        instanceIDs.append(instance.id)
                    }
                }
                let quantity = intValue(raw["quantity"]) ?? max(instanceIDs.count, 1)
                guard quantity > 0 else {
                    return fail("bad_quantity", "BOM quantity must be positive.")
                }
                entries.append(CADDrawingBOMEntry(
                    id: uuidValue(raw["id"]) ?? UUID(),
                    itemNumber: number,
                    name: name,
                    partNumber: (raw["partNumber"] as? String) ?? "",
                    bodyID: bodyID,
                    instanceIDs: instanceIDs,
                    quantity: quantity))
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
        // Explicit BOMs may intentionally list one body twice (different
        // items); keep the first row as the stable id/number source instead of
        // trapping on duplicate dictionary keys.
        var oldByBody: [UUID: CADDrawingBOMEntry] = [:]
        for old in page.bom?.entries ?? [] where oldByBody[old.bodyID] == nil {
            oldByBody[old.bodyID] = old
        }
        var groups: [(bodyID: UUID, instances: [CADAssemblyInstance])] = []
        var indexByBody: [UUID: Int] = [:]
        for instance in assembly.instances where !instance.isHidden {
            let bodyID = effectiveBodyID(instance)
            guard filter.isEmpty || filter.contains(bodyID) else { continue }
            if let existing = indexByBody[bodyID] {
                groups[existing].instances.append(instance)
            } else {
                indexByBody[bodyID] = groups.count
                groups.append((bodyID, [instance]))
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
            let old = oldByBody[group.bodyID]
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
                partNumber: old?.partNumber ?? "",
                bodyID: group.bodyID,
                instanceIDs: group.instances.map(\.id),
                quantity: group.instances.count))
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
                                       page: page, projection: projection)
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
            text: args["text"] as? String)
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
        let required = kind == .angle ? 3 : 2
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
                        "Provide drawingPoints (page space) or modelPoints with an instance binding.")
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
        let plane = plane(for: page)
        if !modelPoints.isEmpty, instance == nil {
            return fail("missing_instance",
                        "Body-local modelPoints need an assembly instance frame.")
        }
        if modelPoints.isEmpty {
            guard let plane else {
                return fail("bad_view_direction", "The page's view direction is invalid.")
            }
            guard let instance, let source else {
                return fail("missing_instance",
                            "A dimension from drawing points must reference an assembly instance; "
                            + "pass modelPoints with a page-local frame only when bound.")
            }
            guard let world = instanceWorldTransform(instance: instance, source: source, page: page) else {
                return fail("unknown_instance", "The instance transform is not placeable.")
            }
            for point in drawingPoints {
                guard let local = bodyLocalPointFromDrawing(point, page: page, plane: plane,
                                                           world: world, source: source) else {
                    return fail("bad_points", "A drawing point could not be mapped onto the part.")
                }
                modelPoints.append(local)
            }
        } else if drawingPoints.isEmpty {
            guard let plane, let instance, let source,
                  let world = instanceWorldTransform(instance: instance, source: source, page: page) else {
                return fail("bad_points",
                            "The page view or instance transform cannot project the model points.")
            }
            for point in modelPoints {
                guard let drawing = drawingPointFromBodyLocal(point, page: page,
                                                              plane: plane, world: world) else {
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
            textOverride: args["text"] as? String, binding: binding)
        page.manualDimensions.append(dimension)
        var updated = set
        updated.pages[index] = page
        if let failure = persist(updated) { return failure }
        let resolved = resolvedManualDimensions(page: page, projection: projectPage(page))
        return ["ok": true, "mutated": true,
                "dimension": resolved.rows.first { ($0["id"] as? String) == dimension.id.uuidString } ?? [:],
                "manualDimensions": resolved.rows]
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
            guard let plane = plane(for: page),
                  let world = instanceWorldTransform(instance: instance, source: source, page: page),
                  let local = bodyLocalPointFromDrawing(position, page: page, plane: plane,
                                                       world: world, source: source) else {
                return fail("bad_position", "The annotation position could not be bound to the part.")
            }
            binding = CADDrawingBinding(instanceID: instance.id, bodyID: source.id.raw,
                                        modelPoints: [local],
                                        sourceRevision: source.meshRevision)
        }
        let annotation = CADDrawingTextAnnotation(
            id: UUID(), text: text, position: position,
            heightMM: height, binding: binding)
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
            if let binding = annotation.binding,
               let instance = loadAssemblyValue()?.instance(binding.instanceID ?? UUID()),
               let source = binding.bodyID.flatMap({ body(for: $0) })
                    ?? body(for: effectiveBodyID(instance)),
               let plane = plane(for: page),
               let world = instanceWorldTransform(instance: instance, source: source, page: page),
               let local = bodyLocalPointFromDrawing(parsed, page: page, plane: plane,
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
            annotations: existing?.annotations ?? [])
        page.customWidthMM = customWidth
        page.customHeightMM = customHeight
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
    private func projectionSources(for page: CADDrawingPage) -> ResolvedProjectionSources {
        var result = ResolvedProjectionSources()
        let assemblyAware = page.assemblyMode || page.kind == .exploded
            || page.explodedViewID != nil
        guard assemblyAware else {
            for id in page.sourceBodyIDs {
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
                                + "the base placements were projected instead.")
        }
        result.explodedViewID = view?.id
        result.explodedViewName = view?.name ?? page.explodedViewName

        let filter = Set(page.sourceBodyIDs)
        let maxInstances = 64
        var instances = assembly.instances.filter { !$0.isHidden }
        if !filter.isEmpty {
            instances = instances.filter { filter.contains($0.copiedBodyID ?? $0.bodyID) }
            let used = Set(instances.map { $0.copiedBodyID ?? $0.bodyID })
            let unused = filter.subtracting(used)
            if !unused.isEmpty {
                result.notes.append("\(unused.count) source body id(s) have no visible assembly instance.")
            }
        }
        if instances.count > maxInstances {
            instances = Array(instances.prefix(maxInstances))
            result.notes.append("Projection is bounded to \(maxInstances) assembly instances; "
                                + "later instances were omitted.")
        }
        if instances.isEmpty {
            result.notes.append("No visible assembly instance matches this page's source bodies.")
        }

        for instance in instances {
            let sourceID = instance.copiedBodyID ?? instance.bodyID
            guard let source = body(for: sourceID) else {
                result.missingBodies.append(sourceID)
                result.missingInstances.append(instance.id)
                continue
            }
            guard instance.transform.isPlaceable else {
                result.missingInstances.append(instance.id)
                result.notes.append("Instance \(instance.name) has a non-placeable transform and was omitted.")
                continue
            }
            var world = instance.transform.placement3D().composed(onto: source.transform)
            if let view {
                let offset = view.offset(for: instance.id)
                if offset != .zero {
                    world = Transform3D(translation: offset).composed(onto: world)
                }
            }
            var placed = Body(id: BodyID(raw: instance.id),
                              name: instance.name,
                              transform: world,
                              render: source.render,
                              edges: source.edges,
                              revision: source.meshRevision)
            // The B-rep is body-local and immutable; carrying it lets exact
            // section/circle work run on the placed transform.
            placed.brep = source.brep
            result.sources.append(ProjectionSource(instanceID: instance.id,
                                                   name: instance.name,
                                                   body: placed))
        }
        if !result.missingInstances.isEmpty {
            result.notes.append("\(result.missingInstances.count) placed instance(s) no longer resolve a body.")
        }
        return result
    }

    private func projectPage(_ page: CADDrawingPage) -> PageProjection {
        let resolved = projectionSources(for: page)
        var notes = resolved.notes
        guard page.scale.isFinite, page.scale > 0 else {
            notes.append("page scale is invalid; nothing was projected.")
            return PageProjection(entities: [], notes: notes,
                                  missing: resolved.missingBodies,
                                  missingInstances: resolved.missingInstances,
                                  explodedViewID: resolved.explodedViewID,
                                  explodedViewName: resolved.explodedViewName)
        }
        let header = PageProjection(entities: [], notes: notes,
                                    missing: resolved.missingBodies,
                                    missingInstances: resolved.missingInstances,
                                    explodedViewID: resolved.explodedViewID,
                                    explodedViewName: resolved.explodedViewName)
        guard !resolved.sources.isEmpty else { return header }
        switch page.kind {
        case .section:
            return projectSection(page, sources: resolved.sources,
                                  header: header)
        case .front, .top, .side, .iso, .exploded:
            return projectView(page, sources: resolved.sources,
                               header: header)
        case .detail:
            return projectDetail(page, sources: resolved.sources,
                                 header: header)
        }
    }

    /// The in-plane frame for a page: `SectionKit.frame(normal:xAxisHint:)`
    /// with the page's own view normal and up hint, matching how section loops
    /// get their coordinates.
    private func plane(for page: CADDrawingPage) -> SketchPlane? {
        let normal: SIMD3<Double>
        switch page.kind {
        case .section:
            guard let stored = page.sectionNormal, simd_length(stored) > 1e-9 else { return nil }
            normal = simd_normalize(stored)
        default:
            guard simd_length(page.viewNormal) > 1e-9 else { return nil }
            normal = simd_normalize(page.viewNormal)
        }
        let frame = SectionKit.frame(normal: normal, xAxisHint: page.viewUp)
        return SketchPlane(origin: .zero, xAxis: frame.xAxis, yAxis: frame.yAxis)
    }

    private func projectView(_ page: CADDrawingPage, sources: [ProjectionSource],
                             header: PageProjection) -> PageProjection {
        guard let plane = plane(for: page) else {
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
            projected = projected.map { $0.scaled(by: page.scale) }
            entities.append(contentsOf: projected)
            if let id = source.instanceID {
                groups[id, default: []].append(contentsOf: projected)
            }
        }
        return completedProjection(header: header, page: page,
                                   entities: entities, groups: groups,
                                   sources: sources)
    }

    private func projectSection(_ page: CADDrawingPage, sources: [ProjectionSource],
                                header: PageProjection) -> PageProjection {
        guard let origin = page.sectionOrigin,
              let storedNormal = page.sectionNormal,
              simd_length(storedNormal) > 1e-9 else {
            var result = header
            result.notes.append("section pages need sectionOrigin and sectionNormal")
            return result
        }
        let normal = simd_normalize(storedNormal)
        let frame = SectionKit.frame(normal: normal, xAxisHint: page.viewUp)
        var entities: [ProjectedEntity] = []
        var groups: [UUID: [ProjectedEntity]] = [:]
        var skipped = 0
        for source in sources {
            guard let brep = source.body.brep else { skipped += 1; continue }
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
                    shape: .polyline(points: loop.points.map { $0 * page.scale },
                                     closed: loop.closed),
                    layer: "section",
                    area: loop.area * page.scale * page.scale))
            }
            entities.append(contentsOf: projected)
            if let id = source.instanceID {
                groups[id, default: []].append(contentsOf: projected)
            }
        }
        var result = completedProjection(header: header, page: page,
                                         entities: entities, groups: groups,
                                         sources: sources)
        if skipped > 0 {
            result.notes.append("\(skipped) mesh-only body/bodies skipped in section (no B-rep).")
        }
        return result
    }

    private func projectDetail(_ page: CADDrawingPage, sources: [ProjectionSource],
                               header: PageProjection) -> PageProjection {
        var header = header
        guard let plane = plane(for: page),
              let centerPoint = page.detailOrigin,
              let windowSize = page.detailSizeMM,
              windowSize.x > 0, windowSize.y > 0 else {
            header.notes.append("detail window is missing; projecting the full view.")
            return projectView(page, sources: sources, header: header)
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
            clippedEntities = clippedEntities.map { $0.scaled(by: page.scale) }
            entities.append(contentsOf: clippedEntities)
            if let id = source.instanceID {
                groups[id, default: []].append(contentsOf: clippedEntities)
            }
        }
        return completedProjection(header: header, page: page,
                                   entities: entities, groups: groups,
                                   sources: sources)
    }

    private func completedProjection(header: PageProjection,
                                     page: CADDrawingPage,
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
        _ = page
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
        let scale = page.scale.isFinite && page.scale > 0 ? page.scale : 1
        var dims: [DrawingDimension] = []
        guard let bounds = entityBounds(projection.entities) else { return dims }
        let width = bounds.max.x - bounds.min.x
        let height = bounds.max.y - bounds.min.y
        if width > 1e-9 {
            dims.append(linearDimension(axis: "x", value: width / scale, bounds: bounds))
        }
        if height > 1e-9 {
            dims.append(linearDimension(axis: "y", value: height / scale, bounds: bounds))
        }
        for circle in detectedCircles(projection) {
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
        var circles: [DetectedCircle] = []
        for entity in projection.entities {
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

    private struct ResolvedAnnotations {
        var balloons: [[String: Any]] = []
        var manualDimensions: [[String: Any]] = []
        var annotations: [[String: Any]] = []
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
        guard instance.transform.isPlaceable else { return nil }
        var world = instance.transform.placement3D().composed(onto: source.transform)
        if let id = page.explodedViewID,
           let view = loadAssemblyValue()?.explodedView(id) {
            let offset = view.offset(for: instance.id)
            if offset != .zero {
                world = Transform3D(translation: offset).composed(onto: world)
            }
        }
        return world
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
        guard page.scale.isFinite, page.scale > 0 else { return nil }
        let modelPoint = plane.origin + plane.xAxis * (drawing.x / page.scale)
            + plane.yAxis * (drawing.y / page.scale)
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
        guard page.scale.isFinite, page.scale > 0 else { return nil }
        let point = plane.toLocal(world.applying(to: local))
        return point * page.scale
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
                                   projection: PageProjection) -> SIMD2<Double> {
        if let bounds = instanceBounds(instanceID, projection: projection) {
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
            let entry = page.bom?.entry(id: balloon.bomEntryID ?? UUID())
                ?? page.bom?.entry(itemNumber: balloon.itemNumber)
            let instance = balloon.instanceID.flatMap { assembly?.instance($0) }
            var target = balloon.target
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
                    if let bounds = instanceBounds(instance.id, projection: projection) {
                        target = nearestBoundaryPoint(to: balloon.anchor, bounds: bounds)
                    } else {
                        stale = true
                        reasons.append("The instance has no projected geometry on this page.")
                        target = balloon.anchor + SIMD2(10, 10)
                    }
                }
            } else {
                invalid = true
                reasons.append("The associated assembly instance no longer exists.")
                target = target ?? balloon.anchor + SIMD2(10, 10)
            }
            if let entry {
                let liveCount = entry.instanceIDs.compactMap { assembly?.instance($0) }
                    .filter { effectiveBodyID($0) == entry.bodyID }.count
                if liveCount != entry.quantity {
                    stale = true
                    reasons.append("The item quantity differs from the captured BOM.")
                }
            }
            var row: [String: Any] = [
                "id": balloon.id.uuidString,
                "itemNumber": balloon.itemNumber,
                "text": balloon.text ?? "\(balloon.itemNumber)",
                "anchor": pointPayload(balloon.anchor),
                "target": pointPayload(target ?? balloon.anchor),
                "stale": stale,
                "invalid": invalid,
                "bomEntryID": ((entry?.id.uuidString ?? balloon.bomEntryID?.uuidString) as Any?) ?? NSNull(),
                "instanceID": (balloon.instanceID?.uuidString as Any?) ?? NSNull(),
            ]
            if !reasons.isEmpty { row["reasons"] = reasons }
            return row
        }
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

    private func resolvedManualDimensions(page: CADDrawingPage,
                                          projection: PageProjection)
        -> ResolvedAnnotations {
        var result = ResolvedAnnotations()
        let assembly = loadAssemblyValue()
        let plane = plane(for: page)
        for dimension in page.manualDimensions {
            var points = dimension.drawingPoints
            var value = dimension.value
            var textPosition = dimension.textPosition
            var stale = false
            var invalid = false
            var reasons: [String] = []
            var currentRevision: UInt64?
            if let binding = dimension.binding {
                let instance = binding.instanceID.flatMap { assembly?.instance($0) }
                let source = binding.bodyID.flatMap { body(for: $0) }
                    ?? instance.flatMap { body(for: effectiveBodyID($0)) }
                if let instance, let source {
                    currentRevision = source.meshRevision
                    if let recorded = binding.sourceRevision, recorded != source.meshRevision {
                        stale = true
                        reasons.append("The source part changed since this dimension was placed.")
                    }
                    if let plane,
                       let world = instanceWorldTransform(instance: instance,
                                                          source: source, page: page) {
                        let live = binding.modelPoints.compactMap {
                            drawingPointFromBodyLocal($0, page: page, plane: plane, world: world)
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
                            reasons.append("The bound part geometry no longer projects.")
                        }
                    } else {
                        invalid = true
                        reasons.append("The page view or instance transform is invalid.")
                    }
                } else {
                    invalid = true
                    reasons.append("The bound instance or source body no longer exists.")
                }
            } else {
                reasons.append("This dimension is not bound to a part; it will not follow the model.")
            }
            let text = dimension.textOverride
                ?? dimensionText(kind: dimension.kind, value: value)
            var row: [String: Any] = [
                "id": dimension.id.uuidString,
                "kind": dimension.kind.rawValue,
                "value": value,
                "unit": dimension.kind == .angle ? "deg" : "mm",
                "text": text,
                "textPosition": pointPayload(textPosition),
                "drawingPoints": points.map(pointPayload),
                "stale": stale,
                "invalid": invalid,
                "unbound": dimension.binding == nil,
                "binding": bindingPayload(dimension.binding,
                                          currentRevision: currentRevision),
            ]
            if !reasons.isEmpty { row["reasons"] = reasons }
            result.manualDimensions.append(row)
            if stale || invalid {
                result.issues.append("Dimension \(dimension.id.uuidString): "
                                     + reasons.joined(separator: " "))
            }
        }
        result.balloons = resolvedBalloons(page: page, projection: projection)
        result.annotations = page.annotations.map {
            annotationRow($0, page: page, projection: projection)
        }
        return result
    }

    private func annotationRow(_ annotation: CADDrawingTextAnnotation,
                               page: CADDrawingPage,
                               projection: PageProjection) -> [String: Any] {
        let assembly = loadAssemblyValue()
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
            if let plane = plane(for: page),
               let world = instanceWorldTransform(instance: instance, source: source, page: page),
               let live = drawingPointFromBodyLocal(local, page: page, plane: plane, world: world) {
                position = live
            } else {
                invalid = true
                reasons.append("The bound instance no longer projects on this page.")
            }
        }
        var row: [String: Any] = [
            "id": annotation.id.uuidString,
            "text": annotation.text,
            "position": pointPayload(position),
            "heightMM": annotation.heightMM,
            "stale": stale,
            "invalid": invalid,
            "binding": bindingPayload(annotation.binding, currentRevision: currentRevision),
        ]
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

    private func bomReply(page: CADDrawingPage, assembly: CADAssembly?) -> [String: Any] {
        var rows: [[String: Any]] = []
        var issues: [String] = []
        for entry in page.bom?.entries ?? [] {
            let liveInstances = entry.instanceIDs.compactMap { assembly?.instance($0) }
            let missing = entry.instanceIDs.filter { assembly?.instance($0) == nil }
            let matching = liveInstances.filter { effectiveBodyID($0) == entry.bodyID }
            let liveQuantity = matching.count
            let body = body(for: entry.bodyID)
            let stale = !missing.isEmpty || liveQuantity != entry.quantity
            var row: [String: Any] = [
                "id": entry.id.uuidString,
                "itemNumber": entry.itemNumber,
                "name": body?.name ?? entry.name,
                "partNumber": entry.partNumber,
                "bodyID": entry.bodyID.uuidString,
                "instanceIDs": entry.instanceIDs.map(\.uuidString),
                "quantity": liveQuantity,
                "capturedQuantity": entry.quantity,
                "stale": stale,
                "missingInstanceIDs": missing.map(\.uuidString),
                "missingBody": body == nil,
            ]
            if !missing.isEmpty {
                issues.append("BOM item \(entry.itemNumber) is missing \(missing.count) instance(s).")
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
        if page.bom == nil { payload["bom"] = NSNull() }
        return payload
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
                  let rawPoints = row["drawingPoints"] as? [[Double]],
                  let text = row["text"] as? String else { continue }
            let points = rawPoints.compactMap { values -> SIMD2<Double>? in
                guard values.count == 2 else { return nil }
                return SIMD2(values[0], values[1])
            }
            guard points.count >= 2 else { continue }
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
        ]
        let centerlines = page.showCenterlines ? centerlineSegments(projection) : []
        if page.showCenterlines { counts["centerlines"] = centerlines.count }
        let assembly = loadAssemblyValue()
        let instanceRows = projection.instances.map { instance -> [String: Any] in
            var row: [String: Any] = [
                "instanceID": instance.id.uuidString,
                "name": instance.name,
                "entityCount": instance.entities.count,
            ]
            if let bounds = entityBounds(instance.entities) {
                row["bounds"] = [pointPayload(bounds.min), pointPayload(bounds.max)]
            }
            return row
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
        var payload: [String: Any] = [
            "ok": true,
            "mutated": mutated,
            "noRasterization": true,
            "page": pagePayload(page),
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
            "bom": bomReply(page: page, assembly: assembly),
            "instances": instanceRows,
            "notes": projection.notes,
            "missingBodyIDs": projection.missing.map(\.uuidString),
            "missingInstanceIDs": projection.missingInstances.map(\.uuidString),
            "bindingIssues": issues,
        ]
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
        ]
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
        var offset = SIMD2<Double>.zero
        if let bounds = entityBounds(projection.entities)
            ?? entityBounds(graphics.entities) {
            offset = SIMD2(20 - bounds.min.x, 40 - bounds.min.y)
        }
        let placedEntities = graphics.entities.map { $0.translated(by: offset) }
        let placedTexts = graphics.texts.map {
            DrawingText(text: $0.text, position: $0.position + offset,
                        height: $0.height, layer: $0.layer)
        }
        let sheet = sheetGraphics(page: page)
        return RenderGraphics(entities: placedEntities + sheet.entities,
                              texts: placedTexts + sheet.texts)
    }

    private func sheetGraphics(page: CADDrawingPage) -> RenderGraphics {
        let width = max(page.paperWidthMM, 40)
        let height = max(page.paperHeightMM, 40)
        let margin = 8.0
        let frameMin = SIMD2(margin, margin)
        let frameMax = SIMD2(width - margin, height - margin)
        var entities = rectangleEntities(min: frameMin, max: frameMax, layer: "title")
        var texts: [DrawingText] = []
        let blockWidth = min(120.0, frameMax.x - frameMin.x)
        let blockMin = SIMD2(frameMax.x - blockWidth, frameMin.y)
        let blockMax = SIMD2(frameMax.x, frameMin.y + 22)
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
        texts.append(DrawingText(text: scaleText(page.scale),
                                 position: SIMD2(blockMin.x + 72, blockMin.y + 14),
                                 height: 3.5, layer: "title"))
        if !page.partNumbers.isEmpty {
            texts.append(DrawingText(text: page.partNumbers.joined(separator: ", "),
                                     position: SIMD2(blockMin.x + 72, blockMin.y + 4),
                                     height: 3.5, layer: "title"))
        }
        if page.showBOM, let bom = page.bom, !bom.entries.isEmpty {
            let table = bomTableGraphics(page: page, bom: bom,
                                         frameMin: frameMin, frameMax: frameMax,
                                         titleBlockWidth: blockWidth)
            entities.append(contentsOf: table.entities)
            texts.append(contentsOf: table.texts)
        }
        return RenderGraphics(entities: entities, texts: texts)
    }

    /// Vector BOM table in the free bottom-left sheet area. Shared instances
    /// group by part definition; the quantity is the LIVE count, so a stale
    /// captured quantity is visible in the row rather than silently reused.
    private func bomTableGraphics(page: CADDrawingPage,
                                  bom: CADDrawingBOM,
                                  frameMin: SIMD2<Double>,
                                  frameMax: SIMD2<Double>,
                                  titleBlockWidth: Double) -> RenderGraphics {
        let reply = bomReply(page: page, assembly: loadAssemblyValue())
        let rows = (reply["entries"] as? [[String: Any]]) ?? []
        guard !rows.isEmpty else { return RenderGraphics(entities: [], texts: []) }
        let available = frameMax.x - frameMin.x - titleBlockWidth - 14
        let tableWidth = min(132, max(64, available))
        let rowHeight = 5.0
        let maxRows = 8
        let displayRows = Array(rows.prefix(maxRows))
        let tableHeight = rowHeight * Double(displayRows.count + 1)
        let minPoint = SIMD2(frameMin.x + 2, frameMin.y + 2)
        let maxPoint = SIMD2(minPoint.x + tableWidth, minPoint.y + tableHeight)
        var entities = rectangleEntities(min: minPoint, max: maxPoint, layer: "bom")
        var texts: [DrawingText] = []
        let partWidth: Double = tableWidth >= 110 ? 40 : 0
        let itemWidth = 10.0
        let quantityWidth = 12.0
        let nameWidth = tableWidth - itemWidth - quantityWidth - partWidth
        let itemX = minPoint.x
        let nameX = itemX + itemWidth
        let quantityX = nameX + nameWidth
        let partX = quantityX + quantityWidth
        entities.append(ProjectedEntity(
            shape: .line(SIMD2(nameX, minPoint.y), SIMD2(nameX, maxPoint.y)),
            layer: "bom"))
        entities.append(ProjectedEntity(
            shape: .line(SIMD2(quantityX, minPoint.y), SIMD2(quantityX, maxPoint.y)),
            layer: "bom"))
        if partWidth > 0 {
            entities.append(ProjectedEntity(
                shape: .line(SIMD2(partX, minPoint.y), SIMD2(partX, maxPoint.y)),
                layer: "bom"))
        }
        for rowIndex in 0...displayRows.count {
            let y = maxPoint.y - rowHeight * Double(rowIndex)
            if rowIndex > 0 {
                entities.append(ProjectedEntity(
                    shape: .line(SIMD2(minPoint.x, y), SIMD2(maxPoint.x, y)),
                    layer: "bom"))
            }
            let baseline = y - rowHeight + 1.4
            if rowIndex == 0 {
                texts.append(DrawingText(text: "#", position: SIMD2(itemX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: "Part", position: SIMD2(nameX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: "Qty", position: SIMD2(quantityX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                if partWidth > 0 {
                    texts.append(DrawingText(text: "Part no.",
                                             position: SIMD2(partX + 1, baseline),
                                             height: 2.8, layer: "bom"))
                }
            } else {
                let row = displayRows[rowIndex - 1]
                let item = row["itemNumber"] as? Int ?? rowIndex
                let name = (row["name"] as? String) ?? "—"
                let quantity = row["quantity"] as? Int ?? 0
                texts.append(DrawingText(text: "\(item)",
                                         position: SIMD2(itemX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: String(name.prefix(40)),
                                         position: SIMD2(nameX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                texts.append(DrawingText(text: "\(quantity)",
                                         position: SIMD2(quantityX + 1, baseline),
                                         height: 2.8, layer: "bom"))
                if partWidth > 0 {
                    let part = (row["partNumber"] as? String) ?? ""
                    texts.append(DrawingText(text: String(part.prefix(24)),
                                             position: SIMD2(partX + 1, baseline),
                                             height: 2.8, layer: "bom"))
                }
            }
        }
        return RenderGraphics(entities: entities, texts: texts)
    }

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
            let width = isCenterline ? 0.18 : 0.25
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
        // floor to ~1.5px so the Canvas asset stays legible; PDF/SVG/DXF keep
        // their exact drawing widths.
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
                out += "<g id=\"\(groupName)\" fill=\"none\" stroke=\"#000000\""
                out += " stroke-width=\"0.25\">\n"
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
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
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
    private func persist(_ set: CADDrawingSet) -> [String: Any]? {
        guard set.schemaVersion <= CADDrawingSet.currentSchemaVersion else {
            return fail("unsupported_version",
                        "The drawing set uses schema v\(set.schemaVersion), newer than this build "
                        + "(v\(CADDrawingSet.currentSchemaVersion)); edits are refused.")
        }
        var updated = set
        // v3 is additive: old v1/v2 pages decoded with defaults, but the first
        // write this build produces is honestly stamped v3 so an older reader
        // cannot silently drop the new fields on a later edit.
        updated.schemaVersion = CADDrawingSet.currentSchemaVersion
        do {
            let data = try updated.encoded()
            document.session.perform(SetDrawingsDataCommand(
                before: document.session.document.drawingsData, after: data))
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

    /// Informational revision for the status line: the max `meshRevision`
    /// over resolvable sources. NOT the staleness authority (see
    /// `liveFingerprint`).
    private func maxMeshRevision(for page: CADDrawingPage) -> UInt64? {
        var revision: UInt64?
        if pageIsAssemblyAware(page) {
            let filter = Set(page.sourceBodyIDs)
            for instance in loadAssemblyValue()?.instances ?? [] where !instance.isHidden {
                let id = effectiveBodyID(instance)
                guard filter.isEmpty || filter.contains(id),
                      let source = body(for: id) else { continue }
                revision = max(revision ?? 0, source.meshRevision)
            }
            return revision
        }
        for id in page.sourceBodyIDs {
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
        guard pageIsAssemblyAware(page) else {
            return CADDrawingSourceFingerprint(sources: page.sourceBodyIDs.map { id in
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
        let filter = Set(page.sourceBodyIDs)
        var instances = (assembly?.instances ?? []).filter { !$0.isHidden }
        if !filter.isEmpty {
            instances = instances.filter { filter.contains(effectiveBodyID($0)) }
        }
        if instances.count > 64 { instances = Array(instances.prefix(64)) }

        var sourceIDs: [UUID] = []
        var seen = Set<UUID>()
        if page.sourceBodyIDs.isEmpty {
            for instance in instances {
                let id = effectiveBodyID(instance)
                if seen.insert(id).inserted { sourceIDs.append(id) }
            }
        } else {
            sourceIDs = page.sourceBodyIDs
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
