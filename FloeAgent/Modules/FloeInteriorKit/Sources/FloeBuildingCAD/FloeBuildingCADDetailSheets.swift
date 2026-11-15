// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

// MARK: - Detail page builder

/// Builds the independently persisted detail pages for one cabinet:
///
/// * `assembly` — front/top/side/iso of the installed 19-panel assembly;
/// * `exploded` — the same placed instances under a real named
///   `CADExplodedView` (created/updated through `CADAssemblyService`);
/// * `internal-elevation` — front/side/top of the carcass with the `front`
///   (door) panels deliberately removed from a verified instance-scoped
///   snapshot and listed explicitly in the binding.
///
/// The builder only uses public `CADDrawingService` / `CADAssemblyService`
/// actions on the supplied native document. It never invents projection
/// geometry, never raises the 64-instance budget, and refuses a page whose
/// projection is incomplete or blocked.
@MainActor
struct FloeBuildingCADDetailSheetBuilder {
    let document: FloeCADDocument
    let cabinet: FloeBuildingCADCabinetBinding
    let assembly: CabinetAssembly
    let options: FloeBuildingCADSheetOptions

    struct PageResult {
        var pageID: UUID
        var viewIDs: [String: UUID]
        var dimensionBindings: [FloeBuildingCADDimensionBinding]
        var annotationBindings: [FloeBuildingCADAnnotationBinding]
        var paper: String
        var title: String
        var explodedViewID: UUID?
        var explodedViewName: String?

        func detail(role: FloeBuildingCADDetailSheet.Role,
                    cabinet: FloeBuildingCADCabinetBinding,
                    documentScope: String,
                    snapshotPath: String,
                    snapshotIdentity: FloeBuildingCADNativeIdentity,
                    sourceIdentity: FloeBuildingCADNativeIdentity,
                    sourceDetailSnapshotPath: String? = nil,
                    excludedPanelIDs: [String],
                    excludedPanelInstanceIDs: [UUID],
                    excludedAssemblyInstanceIDs: [UUID],
                    sourceCabinetIdentity: FloeBuildingCADNativeIdentity)
            -> FloeBuildingCADDetailSheet {
            FloeBuildingCADDetailSheet(
                cabinetID: cabinet.cabinetID,
                role: role.rawValue, pageID: pageID, viewIDs: viewIDs,
                paper: paper, title: title, documentScope: documentScope,
                snapshotRelativePath: snapshotPath,
                snapshotIdentity: snapshotIdentity,
                sourceIdentity: sourceIdentity,
                sourceDetailSnapshotRelativePath: sourceDetailSnapshotPath,
                excludedPanelIDs: excludedPanelIDs,
                excludedPanelInstanceIDs: excludedPanelInstanceIDs,
                excludedAssemblyInstanceIDs: excludedAssemblyInstanceIDs,
                explodedViewID: explodedViewID,
                explodedViewName: explodedViewName,
                dimensionBindings: dimensionBindings,
                annotationBindings: annotationBindings,
                snapshotCabinetBinding: cabinet,
                sourceCabinetUpdatedAtIdentity: sourceCabinetIdentity,
                createdAtIdentity: snapshotIdentity,
                updatedAtIdentity: snapshotIdentity)
        }
    }

    private struct ViewSpec {
        var kind: CabinetTechnicalView
        var nativeKind: String
        var role: String
        var displayName: String
    }

    private struct DetailDimensionSpec {
        var role: String
        var viewRole: String
        var drawingPoints: [[Double]]
        var expectedValue: Double
        var defaultTextPosition: [Double]
    }

    // MARK: Pages

    func createAssemblyPage(previousLayout: [String: FloeBuildingCADDimensionLayout],
                            migratedAnnotations: [FloeBuildingCADMigratedAnnotation])
        throws -> PageResult {
        let specs = [
            ViewSpec(kind: .front, nativeKind: "front", role: "front", displayName: "Front"),
            ViewSpec(kind: .top, nativeKind: "top", role: "top", displayName: "Top"),
            ViewSpec(kind: .side, nativeKind: "side", role: "side", displayName: "Side"),
            ViewSpec(kind: .isometric, nativeKind: "iso", role: "isometric", displayName: "Isometric"),
        ]
        return try createPage(
            pageKind: "front", title: "\(cabinet.name) — Assembly",
            views: specs, explodedViewID: nil, showDimensions: true,
            includeInternalDimensions: false, previousLayout: previousLayout,
            migratedAnnotations: migratedAnnotations,
            expectedInstanceIDs: Set(cabinet.panelBindings.map(\.instanceID)))
    }

    func createExplodedPage(existingExplodedViewID: UUID?,
                            previousLayout: [String: FloeBuildingCADDimensionLayout],
                            migratedAnnotations: [FloeBuildingCADMigratedAnnotation])
        throws -> PageResult {
        let view = try ensureExplodedView(existingID: existingExplodedViewID)
        let specs = [
            ViewSpec(kind: .front, nativeKind: "front", role: "front", displayName: "Front"),
            ViewSpec(kind: .side, nativeKind: "side", role: "side", displayName: "Side"),
            ViewSpec(kind: .top, nativeKind: "top", role: "top", displayName: "Top"),
            ViewSpec(kind: .isometric, nativeKind: "exploded", role: "exploded", displayName: "Exploded"),
        ]
        var result = try createPage(
            pageKind: "exploded", title: "\(cabinet.name) — Exploded assembly",
            views: specs, explodedViewID: view.id, showDimensions: false,
            includeInternalDimensions: false, scaleMultiplier: 2,
            previousLayout: previousLayout,
            migratedAnnotations: migratedAnnotations,
            expectedInstanceIDs: Set(cabinet.panelBindings.map(\.instanceID)))
        result.explodedViewID = view.id
        result.explodedViewName = view.name
        return result
    }

    func createInternalPage(previousLayout: [String: FloeBuildingCADDimensionLayout],
                            migratedAnnotations: [FloeBuildingCADMigratedAnnotation])
        throws -> PageResult {
        let specs = [
            ViewSpec(kind: .internalElevation, nativeKind: "front",
                     role: "front", displayName: "Internal elevation"),
            ViewSpec(kind: .side, nativeKind: "side", role: "side", displayName: "Internal side"),
            ViewSpec(kind: .top, nativeKind: "top", role: "top", displayName: "Internal top"),
        ]
        let expected = Set(cabinet.panelBindings
            .filter { $0.role != CabinetPanelRole.front.rawValue }
            .map(\.instanceID))
        guard expected.count == cabinet.panelBindings.count - frontPanelBindings.count,
              !expected.isEmpty else {
            throw FloeBuildingCADError.invalidBinding(
                "The internal elevation has no non-door cabinet panels.")
        }
        return try createPage(
            pageKind: "front", title: "\(cabinet.name) — Internal elevation",
            views: specs, explodedViewID: nil, showDimensions: true,
            includeInternalDimensions: true, previousLayout: previousLayout,
            migratedAnnotations: migratedAnnotations,
            expectedInstanceIDs: expected)
    }

    // MARK: Page primitives

    private func createPage(pageKind: String, title: String,
                            views: [ViewSpec], explodedViewID: UUID?,
                            showDimensions: Bool,
                            includeInternalDimensions: Bool,
                            scaleMultiplier: Double = 1,
                            previousLayout: [String: FloeBuildingCADDimensionLayout],
                            migratedAnnotations: [FloeBuildingCADMigratedAnnotation],
                            expectedInstanceIDs: Set<UUID>) throws -> PageResult {
        guard !views.isEmpty else {
            throw FloeBuildingCADError.invalidInput("A detail page needs at least one view.")
        }
        let paperName = options.paper.lowercased()
        guard let paper = FloeBuildingCADSheetBuilder.paperSpec(paperName) else {
            throw FloeBuildingCADError.invalidInput("Unsupported paper \(options.paper).")
        }
        let planner = try CabinetSheetPlanner.make(
            assembly, paperWidthMM: paper.width, paperHeightMM: paper.height,
            maximumNativeSources: 64)
        let service = CADDrawingService(document: document)

        guard let first = views.first else {
            throw FloeBuildingCADError.invalidInput("The detail page has no first view.")
        }
        var pageArgs: [String: Any] = [
            "kind": first.nativeKind,
            "title": title,
            "paper": paperName,
            "scale": 1 / (scaleDenominator(for: first.kind, planner: planner) * scaleMultiplier),
            "assemblyMode": true,
            "showDimensions": showDimensions,
        ]
        pageArgs.merge(try axes(for: first.kind, planner: planner)) { _, new in new }
        if let explodedViewID {
            pageArgs["explodedViewID"] = explodedViewID.uuidString
        }
        let created = try checked(service.handle(action: "addPage", args: pageArgs), "addPage")
        guard let pageObject = created["page"] as? [String: Any],
              let pageID = FloeBuildingCADGeometry.uuid(pageObject["id"]),
              let pageViews = pageObject["views"] as? [[String: Any]],
              let firstID = pageViews.first.flatMap({ FloeBuildingCADGeometry.uuid($0["id"]) }) else {
            throw FloeBuildingCADError.invalidNativeState("addPage returned no detail page/view id.")
        }
        var viewIDs: [String: UUID] = [first.role: firstID]
        for spec in views.dropFirst() {
            var input: [String: Any] = [
                "pageID": pageID.uuidString,
                "kind": spec.nativeKind,
                "name": spec.displayName,
                "scale": 1 / (scaleDenominator(for: spec.kind, planner: planner) * scaleMultiplier),
                "alignmentPlacement": "free",
            ]
            input.merge(try axes(for: spec.kind, planner: planner)) { _, new in new }
            let reply = try checked(service.handle(action: "addView", args: input), "addView")
            guard let row = reply["view"] as? [String: Any],
                  let id = FloeBuildingCADGeometry.uuid(row["id"]) else {
                throw FloeBuildingCADError.invalidNativeState("addView returned no detail view id.")
            }
            viewIDs[spec.role] = id
        }
        try project(service, pageID: pageID)
        try placeViews(service, pageID: pageID, views: views,
                       viewIDs: viewIDs, planner: planner)
        try project(service, pageID: pageID)
        var dimensions: [FloeBuildingCADDimensionBinding] = []
        if includeInternalDimensions {
            dimensions = try addInternalDimensions(
                service, pageID: pageID, viewIDs: viewIDs,
                previousLayout: previousLayout)
        }
        let annotationBindings = try addMigratedAnnotations(
            service, pageID: pageID, viewIDs: viewIDs,
            migrated: migratedAnnotations)
        try project(service, pageID: pageID)
        try verify(service, pageID: pageID, viewIDs: viewIDs,
                   expectedInstanceIDs: expectedInstanceIDs,
                   explodedViewID: explodedViewID,
                   needFormalDimensions: includeInternalDimensions)
        return PageResult(pageID: pageID, viewIDs: viewIDs,
                          dimensionBindings: dimensions,
                          annotationBindings: annotationBindings,
                          paper: paperName, title: title,
                          explodedViewID: explodedViewID,
                          explodedViewName: explodedViewID.flatMap { explodedViewName(for: $0) })
    }

    private func checked(_ reply: [String: Any], _ context: String) throws -> [String: Any] {
        guard reply["ok"] as? Bool == true else {
            throw FloeBuildingCADError.invalidNativeState(
                "\(context) was refused: \(reply["message"] as? String ?? "unknown")")
        }
        return reply
    }

    private func project(_ service: CADDrawingService, pageID: UUID) throws {
        let reply = service.handle(action: "project", args: ["pageID": pageID.uuidString])
        guard reply["ok"] as? Bool == true,
              reply["projectionComplete"] as? Bool == true,
              reply["outputBlocked"] as? Bool == false else {
            throw FloeBuildingCADError.projectionIncomplete(
                reply["message"] as? String ?? "The native detail projection is incomplete or blocked.")
        }
    }

    private func pageGeometry(_ service: CADDrawingService, pageID: UUID) throws -> [String: Any] {
        let payload = service.pageGeometry(pageID: pageID)
        guard payload["ok"] as? Bool == true else {
            throw FloeBuildingCADError.invalidNativeState(
                payload["message"] as? String ?? "The detail page geometry could not be read.")
        }
        return payload
    }

    private func placeViews(_ service: CADDrawingService, pageID: UUID,
                            views: [ViewSpec], viewIDs: [String: UUID],
                            planner: CabinetCombinationSheet) throws {
        let geometry = try pageGeometry(service, pageID: pageID)
        guard let rows = geometry["views"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState("The projected detail page has no views.")
        }
        for spec in views {
            guard let id = viewIDs[spec.role],
                  let row = rows.first(where: { FloeBuildingCADGeometry.uuid($0["id"]) == id }),
                  let boundsRows = row["localBounds"] as? [[Any]],
                  boundsRows.count == 2 else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The \(spec.role) detail view has no local bounds.")
            }
            let minimum = boundsRows[0].compactMap { FloeBuildingCADGeometry.number($0) }
            let maximum = boundsRows[1].compactMap { FloeBuildingCADGeometry.number($0) }
            guard minimum.count == 2, maximum.count == 2 else {
                throw FloeBuildingCADError.invalidNativeState("A detail view bound is not two-dimensional.")
            }
            let centre = plannerCentre(for: spec.kind, planner: planner)
            let offset = [centre.x - (minimum[0] + maximum[0]) / 2,
                          centre.y - (minimum[1] + maximum[1]) / 2]
            let reply = service.handle(action: "updateView", args: [
                "pageID": pageID.uuidString,
                "viewID": id.uuidString,
                "alignmentPlacement": "free",
                "offset": offset,
            ])
            _ = try checked(reply, "updateView")
        }
    }

    private func plannerView(_ kind: CabinetTechnicalView,
                             planner: CabinetCombinationSheet) throws -> CabinetSheetViewSpec {
        let mapped: CabinetTechnicalView
        switch kind {
        case .internalElevation: mapped = .internalElevation
        case .front: mapped = .front
        case .side: mapped = .side
        case .top: mapped = .top
        case .section: mapped = .section
        case .isometric: mapped = .isometric
        }
        guard let view = planner.views.first(where: { $0.kind == mapped }) else {
            throw FloeBuildingCADError.invalidInput("The sheet planner has no \(mapped.rawValue) view.")
        }
        return view
    }

    private func plannerCentre(for kind: CabinetTechnicalView,
                               planner: CabinetCombinationSheet) -> CabinetPaperPoint {
        (try? plannerView(kind, planner: planner))?.centreOnPaperMM
            ?? CabinetPaperPoint(150, 200)
    }

    private func scaleDenominator(for kind: CabinetTechnicalView,
                                  planner: CabinetCombinationSheet) -> Double {
        (try? plannerView(kind, planner: planner))?.scaleDenominator ?? 10
    }

    private func axes(for kind: CabinetTechnicalView,
                      planner: CabinetCombinationSheet) throws -> [String: Any] {
        let spec = try plannerView(kind, planner: planner)
        let horizontal = spec.horizontalInBuilding
        let vertical = spec.verticalInBuilding
        let normal = InteriorVector3(
            horizontal.y * vertical.z - horizontal.z * vertical.y,
            horizontal.z * vertical.x - horizontal.x * vertical.z,
            horizontal.x * vertical.y - horizontal.y * vertical.x)
        return [
            "viewNormal": FloeBuildingCADGeometry.values(
                FloeBuildingCADGeometry.nativeVector(normal.values)),
            "viewUp": FloeBuildingCADGeometry.values(
                FloeBuildingCADGeometry.nativeVector(horizontal.values)),
        ]
    }

    // MARK: Internal dimensions

    private var frontPanelBindings: [FloeBuildingCADPanelBinding] {
        cabinet.panelBindings.filter { $0.role == CabinetPanelRole.front.rawValue }
    }

    private func addInternalDimensions(_ service: CADDrawingService, pageID: UUID,
                                       viewIDs: [String: UUID],
                                       previousLayout: [String: FloeBuildingCADDimensionLayout])
        throws -> [FloeBuildingCADDimensionBinding] {
        guard let frontViewID = viewIDs["front"] else {
            throw FloeBuildingCADError.invalidNativeState("The internal page has no front view.")
        }
        let geometry = try pageGeometry(service, pageID: pageID)
        let scale = viewScale(geometry, viewID: frontViewID) ?? 1
        let recipe = assembly.recipe
        let t = recipe.carcassMaterial.thicknessMM
        let h = recipe.heightMM
        let w = recipe.widthMM
        let bayCount = Double(recipe.bays.count)
        let bayWidth = (w - 2 * t - (bayCount - 1) * t) / bayCount
        var specs: [DetailDimensionSpec] = [
            DetailDimensionSpec(
                role: "internal-carcass-thickness", viewRole: "front",
                drawingPoints: [[0, h / 2 * scale], [t, h / 2 * scale]],
                expectedValue: t,
                defaultTextPosition: [t * scale + 8, h * 0.12 * scale]),
        ]
        for (index, bay) in recipe.bays.enumerated() {
            let x = t + Double(index) * (bayWidth + t)
            let key = bay.id.uuidString.lowercased()
            specs.append(DetailDimensionSpec(
                role: "internal-bay-width-\(key)", viewRole: "front",
                drawingPoints: [[x * scale, t * 0.5 * scale],
                                [(x + bayWidth) * scale, t * 0.5 * scale]],
                expectedValue: bayWidth,
                defaultTextPosition: [(x + bayWidth / 2) * scale,
                                      t * 0.5 * scale - 10]))
            specs.append(DetailDimensionSpec(
                role: "internal-bay-height-\(key)", viewRole: "front",
                drawingPoints: [[(x + bayWidth / 2) * scale, t * scale],
                                [(x + bayWidth / 2) * scale, (h - t) * scale]],
                expectedValue: h - 2 * t,
                defaultTextPosition: [(x + bayWidth / 2) * scale + 10,
                                      h * 0.5 * scale]))
        }
        var result: [FloeBuildingCADDimensionBinding] = []
        for spec in specs {
            let layout = previousLayout[spec.role]
            let position = layout?.textPosition ?? spec.defaultTextPosition
            guard position.count == 2, position.allSatisfy(\.isFinite) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The internal dimension \(spec.role) has an invalid text position.")
            }
            var args: [String: Any] = [
                "pageID": pageID.uuidString,
                "viewID": frontViewID.uuidString,
                "kind": "length",
                "drawingPoints": spec.drawingPoints,
                "textPosition": position,
            ]
            if let override = layout?.textOverride { args["text"] = override }
            let reply = try checked(service.handle(action: "addDimension", args: args),
                                    "addDimension")
            guard let row = reply["dimension"] as? [String: Any],
                  let dimensionID = FloeBuildingCADGeometry.uuid(row["id"]),
                  let value = FloeBuildingCADGeometry.number(row["value"]),
                  abs(value - spec.expectedValue) <= 0.02 else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The internal dimension \(spec.role) did not produce \(spec.expectedValue) mm.")
            }
            let stored = FloeBuildingCADGeometry.doubleArray(row["localTextPosition"]) ?? position
            result.append(FloeBuildingCADDimensionBinding(
                role: spec.role, dimensionID: dimensionID, viewID: frontViewID,
                textPosition: stored,
                textOverride: row["textOverride"] as? String ?? layout?.textOverride))
        }
        return result
    }

    private func viewScale(_ geometry: [String: Any], viewID: UUID) -> Double? {
        let rows = geometry["views"] as? [[String: Any]] ?? []
        return rows.first { FloeBuildingCADGeometry.uuid($0["id"]) == viewID }
            .flatMap { FloeBuildingCADGeometry.number($0["scale"]) }
    }

    // MARK: Annotations

    private func addMigratedAnnotations(_ service: CADDrawingService,
                                        pageID: UUID,
                                        viewIDs: [String: UUID],
                                        migrated: [FloeBuildingCADMigratedAnnotation])
        throws -> [FloeBuildingCADAnnotationBinding] {
        var result: [FloeBuildingCADAnnotationBinding] = []
        for item in migrated {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let role = item.viewRole, let viewID = viewIDs[role],
                  !text.isEmpty, text.count <= 500,
                  item.localPosition.count == 2,
                  item.localPosition.allSatisfy(\.isFinite) else {
                result.append(FloeBuildingCADAnnotationBinding(
                    stableID: item.stableID, currentID: nil, viewRole: item.viewRole,
                    text: item.text, localPosition: item.localPosition, orphaned: true))
                continue
            }
            let height = item.heightMM.isFinite ? min(max(item.heightMM, 0.5), 50) : 3.5
            let reply = service.handle(action: "addAnnotation", args: [
                "pageID": pageID.uuidString,
                "viewID": viewID.uuidString,
                "text": text,
                "position": item.localPosition,
                "heightMM": height,
            ])
            guard reply["ok"] as? Bool == true,
                  let row = reply["annotation"] as? [String: Any],
                  let id = FloeBuildingCADGeometry.uuid(row["id"]) else {
                result.append(FloeBuildingCADAnnotationBinding(
                    stableID: item.stableID, currentID: nil, viewRole: role,
                    text: text, localPosition: item.localPosition, orphaned: true))
                continue
            }
            result.append(FloeBuildingCADAnnotationBinding(
                stableID: item.stableID, currentID: id, viewRole: role,
                text: text, localPosition: item.localPosition, orphaned: false))
        }
        return result
    }

    // MARK: Exploded view

    private struct ExplodedViewName {
        var id: UUID
        var name: String
    }

    private func explodedViewName(for id: UUID) -> String? {
        let reply = CADAssemblyService(document: document).handle(action: "explodedViews", args: [:])
        let views = reply["views"] as? [[String: Any]] ?? []
        return views.first { FloeBuildingCADGeometry.uuid($0["id"]) == id }?["name"] as? String
    }

    private func ensureExplodedView(existingID: UUID?) throws -> ExplodedViewName {
        let service = CADAssemblyService(document: document)
        let listed = service.handle(action: "explodedViews", args: [:])
        guard listed["ok"] as? Bool == true else {
            throw FloeBuildingCADError.invalidNativeState(
                listed["message"] as? String ?? "The exploded-view list could not be read.")
        }
        let rows = listed["views"] as? [[String: Any]] ?? []
        let stableName = "Cabinet \(cabinet.cabinetID.uuidString.prefix(8)) exploded"
        let entries = explodedEntries()
        let direction = [0.0, 0.0, 1.0]
        if let existingID,
           let row = rows.first(where: { FloeBuildingCADGeometry.uuid($0["id"]) == existingID }) {
            let name = row["name"] as? String ?? stableName
            let updated = service.handle(action: "updateExplodedView", args: [
                "id": existingID.uuidString,
                "direction": direction,
                "distanceMM": 80.0,
                "entries": entries,
            ])
            guard updated["ok"] as? Bool == true,
                  let updatedID = FloeBuildingCADGeometry.uuid(updated["id"]) else {
                throw FloeBuildingCADError.invalidNativeState(
                    updated["message"] as? String ?? "The named exploded view could not be updated.")
            }
            return ExplodedViewName(id: updatedID, name: updated["name"] as? String ?? name)
        }
        func add(_ name: String) -> [String: Any] {
            service.handle(action: "addExplodedView", args: [
                "name": name,
                "direction": direction,
                "distanceMM": 80.0,
                "entries": entries,
            ])
        }
        var added = add(stableName)
        if added["ok"] as? Bool != true,
           (added["error"] as? String) == "duplicate_name" {
            added = add(stableName + " " + String(cabinet.cabinetID.uuidString.prefix(4)))
        }
        guard added["ok"] as? Bool == true,
              let id = FloeBuildingCADGeometry.uuid(added["id"]),
              let name = added["name"] as? String else {
            throw FloeBuildingCADError.invalidNativeState(
                added["message"] as? String ?? "The named exploded view could not be created.")
        }
        return ExplodedViewName(id: id, name: name)
    }

    /// Explicit per-panel explosion vectors in native world coordinates
    /// (+X right, +Y up, +Z toward the viewer). Every panel is listed, so an
    /// unlisted instance can never look accidentally exploded.
    private func explodedEntries() -> [[String: Any]] {
        var result: [[String: Any]] = []
        result.reserveCapacity(cabinet.panelBindings.count)
        for binding in cabinet.panelBindings {
            let direction: [Double]
            let distance: Double
            switch binding.role {
            case "front":
                direction = [0, 0, 1]; distance = 240
            case "back":
                direction = [0, 0, -1]; distance = 150
            case "leftSide":
                direction = [-1, 0, 0]; distance = 180
            case "rightSide":
                direction = [1, 0, 0]; distance = 180
            case "top":
                direction = [0, 1, 0]; distance = 130
            case "bottom":
                direction = [0, -1, 0]; distance = 130
            case "partition":
                direction = [0, 0, 1]; distance = 110
            default:
                direction = [0, 0, 1]; distance = 70
            }
            result.append([
                "instanceID": binding.instanceID.uuidString,
                "direction": direction,
                "distanceMM": distance,
            ])
        }
        return result
    }

    // MARK: Verification

    private func verify(_ service: CADDrawingService, pageID: UUID,
                        viewIDs: [String: UUID],
                        expectedInstanceIDs: Set<UUID>,
                        explodedViewID: UUID?,
                        needFormalDimensions: Bool) throws {
        let geometry = try pageGeometry(service, pageID: pageID)
        guard geometry["projectionComplete"] as? Bool == true,
              geometry["outputBlocked"] as? Bool == false,
              geometry["missingExplodedView"] as? Bool != true,
              let views = geometry["views"] as? [[String: Any]],
              views.count == viewIDs.count else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The detail page did not project all of its views completely.")
        }
        let expectedViewIDs = Set(viewIDs.values)
        guard Set(views.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) }) == expectedViewIDs else {
            throw FloeBuildingCADError.invalidNativeState(
                "The detail page view identities changed during creation.")
        }
        for row in views {
            guard row["instanceCount"] as? Int == expectedInstanceIDs.count,
                  row["projectionComplete"] as? Bool == true,
                  row["outputBlocked"] as? Bool == false,
                  (row["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty,
                  (row["missingBodyIDs"] as? [String] ?? ["missing"]).isEmpty else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "A detail view does not contain exactly the expected cabinet instances.")
            }
        }
        guard let page = geometry["page"] as? [String: Any],
              let fingerprint = page["sourceFingerprint"] as? [String: Any],
              let instances = fingerprint["instances"] as? [[String: Any]] else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The detail page has no verified source-instance fingerprint.")
        }
        let actual = Set(instances.compactMap {
            FloeBuildingCADGeometry.uuid($0["instanceID"] ?? $0["id"])
        })
        guard actual == expectedInstanceIDs else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The detail page source fingerprint contains instances outside its scope.")
        }
        if let explodedViewID {
            guard geometry["explodedView"] is [String: Any],
                  let exploded = geometry["explodedView"] as? [String: Any],
                  (exploded["id"] as? String) == explodedViewID.uuidString,
                  exploded["found"] as? Bool == true,
                  instances.allSatisfy({
                      FloeBuildingCADGeometry.uuid($0["explodedViewID"]) == explodedViewID
                  }) else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "The exploded page does not reference its stored named exploded view.")
            }
        } else if let pageExploded = page["explodedViewID"] as? String,
                  !pageExploded.isEmpty {
            throw FloeBuildingCADError.invalidNativeState(
                "An ordinary detail page unexpectedly carries an exploded view.")
        }
        if needFormalDimensions {
            let manual = geometry["manualDimensions"] as? [[String: Any]] ?? []
            let values = manual.compactMap { FloeBuildingCADGeometry.number($0["value"]) }
            let auto = (geometry["dimensions"] as? [[String: Any]] ?? [])
                .compactMap { FloeBuildingCADGeometry.number($0["value"]) }
            let width = assembly.recipe.widthMM
            let height = assembly.recipe.heightMM
            guard auto.contains(where: { abs($0 - width) <= 0.5 }),
                  auto.contains(where: { abs($0 - height) <= 0.5 }) else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "The internal elevation is missing its automatic overall dimensions.")
            }
            let t = assembly.recipe.carcassMaterial.thicknessMM
            guard values.contains(where: { abs($0 - t) <= 0.02 }) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The internal elevation is missing its carcass thickness dimension.")
            }
            let bayCount = Double(assembly.recipe.bays.count)
            let bayWidth = (width - 2 * t - (bayCount - 1) * t) / bayCount
            guard values.contains(where: { abs($0 - bayWidth) <= 0.02 }),
                  values.contains(where: { abs($0 - (height - 2 * t)) <= 0.02 }) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The internal elevation is missing a formal bay clear dimension.")
            }
        }
    }
}

// MARK: - Session snapshot plumbing

extension FloeBuildingCADSession {
    struct DetailSheetSet {
        var sheets: [FloeBuildingCADDetailSheet]
        var files: [URL]
    }

    struct CapturedDetailAnnotations {
        var migrated: [FloeBuildingCADMigratedAnnotation] = []
        var orphaned: [FloeBuildingCADAnnotationBinding] = []
    }

    /// Create (or rebuild) the internal/assembly/exploded detail pages in
    /// verified cabinet-only snapshots. Previous manual text is remapped by
    /// view role; a bound annotation that cannot be remapped is recorded as
    /// orphaned. The project document is never mutated by this function.
    func makeDetailSheetSet(cabinet: FloeBuildingCADCabinetBinding,
                            assembly: CabinetAssembly,
                            options: FloeBuildingCADSheetOptions,
                            sourceIdentity: FloeBuildingCADNativeIdentity,
                            previous: [FloeBuildingCADDetailSheet])
        async throws -> DetailSheetSet {
        guard options.includeDetailSheets else {
            return DetailSheetSet(sheets: [], files: [])
        }
        var layouts: [String: [String: FloeBuildingCADDimensionLayout]] = [:]
        var migrated: [String: [FloeBuildingCADMigratedAnnotation]] = [:]
        var orphaned: [String: [FloeBuildingCADAnnotationBinding]] = [:]
        for detail in previous {
            layouts[detail.role] = await captureDetailLayout(detail)
            let captured = await captureDetailAnnotations(detail)
            migrated[detail.role] = captured.migrated
            orphaned[detail.role] = captured.orphaned
        }
        var files: [URL] = []
        do {
            let detail = try await createDetailSnapshot(
                cabinet: cabinet, assembly: assembly, options: options,
                sourceIdentity: sourceIdentity,
                previousExplodedViewID: previous.first { $0.role == FloeBuildingCADDetailSheet.Role.exploded.rawValue }?.explodedViewID,
                previousLayouts: layouts,
                migratedAnnotations: migrated)
            files.append(detail.url)
            var sheets: [FloeBuildingCADDetailSheet] = []
            var assemblyPage = detail.assemblyPage
            assemblyPage.annotationBindings.append(contentsOf:
                orphaned[FloeBuildingCADDetailSheet.Role.assembly.rawValue] ?? [])
            sheets.append(assemblyPage.detail(
                role: .assembly, cabinet: cabinet,
                documentScope: "verified-snapshot",
                snapshotPath: detail.relativePath,
                snapshotIdentity: detail.identity,
                sourceIdentity: sourceIdentity,
                excludedPanelIDs: [],
                excludedPanelInstanceIDs: [],
                excludedAssemblyInstanceIDs: detail.removedNonCabinetInstanceIDs,
                sourceCabinetIdentity: cabinet.updatedAtIdentity))
            var explodedPage = detail.explodedPage
            explodedPage.annotationBindings.append(contentsOf:
                orphaned[FloeBuildingCADDetailSheet.Role.exploded.rawValue] ?? [])
            sheets.append(explodedPage.detail(
                role: .exploded, cabinet: cabinet,
                documentScope: "verified-snapshot",
                snapshotPath: detail.relativePath,
                snapshotIdentity: detail.identity,
                sourceIdentity: sourceIdentity,
                excludedPanelIDs: [],
                excludedPanelInstanceIDs: [],
                excludedAssemblyInstanceIDs: detail.removedNonCabinetInstanceIDs,
                sourceCabinetIdentity: cabinet.updatedAtIdentity))

            let internalDetail = try await createInternalSnapshot(
                cabinet: cabinet, assembly: assembly, options: options,
                sourceIdentity: sourceIdentity,
                detailURL: detail.url,
                detailIdentity: detail.identity,
                detailRelativePath: detail.relativePath,
                removedNonCabinetInstanceIDs: detail.removedNonCabinetInstanceIDs,
                previousLayout: layouts[FloeBuildingCADDetailSheet.Role.internalElevation.rawValue] ?? [:],
                migratedAnnotations: migrated[FloeBuildingCADDetailSheet.Role.internalElevation.rawValue] ?? [])
            files.append(internalDetail.url)
            var internalPage = internalDetail.page
            internalPage.annotationBindings.append(contentsOf:
                orphaned[FloeBuildingCADDetailSheet.Role.internalElevation.rawValue] ?? [])
            let frontPanels = cabinet.panelBindings
                .filter { $0.role == CabinetPanelRole.front.rawValue }
            sheets.append(internalPage.detail(
                role: .internalElevation, cabinet: cabinet,
                documentScope: "verified-snapshot",
                snapshotPath: internalDetail.relativePath,
                snapshotIdentity: internalDetail.identity,
                sourceIdentity: sourceIdentity,
                sourceDetailSnapshotPath: detail.relativePath,
                excludedPanelIDs: frontPanels.map(\.panelID),
                excludedPanelInstanceIDs: frontPanels.map(\.instanceID),
                excludedAssemblyInstanceIDs: internalDetail.removedNonCabinetInstanceIDs,
                sourceCabinetIdentity: cabinet.updatedAtIdentity))
            return DetailSheetSet(sheets: sheets, files: files)
        } catch {
            for url in files {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private struct DetailSnapshot {
        var url: URL
        var relativePath: String
        var identity: FloeBuildingCADNativeIdentity
        var removedNonCabinetInstanceIDs: [UUID]
        var assemblyPage: FloeBuildingCADDetailSheetBuilder.PageResult
        var explodedPage: FloeBuildingCADDetailSheetBuilder.PageResult
    }

    private func createDetailSnapshot(cabinet: FloeBuildingCADCabinetBinding,
                                      assembly: CabinetAssembly,
                                      options: FloeBuildingCADSheetOptions,
                                      sourceIdentity: FloeBuildingCADNativeIdentity,
                                      previousExplodedViewID: UUID?,
                                      previousLayouts: [String: [String: FloeBuildingCADDimensionLayout]],
                                      migratedAnnotations: [String: [FloeBuildingCADMigratedAnnotation]])
        async throws -> DetailSnapshot {
        let snapshots = snapshotDirectory.standardizedFileURL
        let parent = document.url.deletingLastPathComponent().standardizedFileURL
        guard snapshots.path.hasPrefix(parent.path + "/") else {
            throw FloeBuildingCADError.invalidInput(
                "The snapshot directory must be inside the project document's parent directory.")
        }
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let unique = UUID().uuidString
        let staging = snapshots.appendingPathComponent(".staging-\(unique)-details.floecad",
                                                        isDirectory: true)
        let final = snapshots.appendingPathComponent(
            "Cabinet-\(cabinet.cabinetID.uuidString)-details-\(unique).floecad",
            isDirectory: true)
        do {
            try FileManager.default.copyItem(at: document.url, to: staging)
            guard let copiedIdentity = await FloeCADDocument.storedIdentity(at: staging),
                  copiedIdentity.revision == sourceIdentity.revision,
                  copiedIdentity.contentSHA256 == sourceIdentity.contentSHA256,
                  copiedIdentity.modelSHA256 == sourceIdentity.modelSHA256 else {
                throw FloeBuildingCADError.staleBinding(
                    "The copied project bytes no longer match the verified source.")
            }
            let copy = try await FloeCADDocument.open(at: staging)
            do {
                let session = FloeBuildingCADSession(document: copy)
                let panelInstances = Set(cabinet.panelBindings.map(\.instanceID))
                let removed = try removeNonCabinetRootInstances(
                    document: copy, panelInstanceIDs: panelInstances)
                let copiedDrawing = CADDrawingService(document: copy)
                for pageID in try session.drawingPageIDs() {
                    let reply = copiedDrawing.handle(action: "removePage",
                                                     args: ["pageID": pageID.uuidString])
                    guard reply["ok"] as? Bool == true else {
                        throw FloeBuildingCADError.invalidNativeState(
                            reply["message"] as? String ?? "A copied project page could not be removed from the detail snapshot.")
                    }
                }
                guard copy.summary().drawingPageCount == 0 else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The detail snapshot still contains copied project drawing pages.")
                }
                try validateCabinetBindingInSnapshot(session, cabinet: cabinet)
                let builder = FloeBuildingCADDetailSheetBuilder(
                    document: copy, cabinet: cabinet, assembly: assembly, options: options)
                let assemblyPage = try builder.createAssemblyPage(
                    previousLayout: previousLayouts[FloeBuildingCADDetailSheet.Role.assembly.rawValue] ?? [:],
                    migratedAnnotations: migratedAnnotations[FloeBuildingCADDetailSheet.Role.assembly.rawValue] ?? [])
                let explodedPage = try builder.createExplodedPage(
                    existingExplodedViewID: previousExplodedViewID,
                    previousLayout: previousLayouts[FloeBuildingCADDetailSheet.Role.exploded.rawValue] ?? [:],
                    migratedAnnotations: migratedAnnotations[FloeBuildingCADDetailSheet.Role.exploded.rawValue] ?? [])
                let saved = await copy.save()
                guard saved.succeeded, !saved.modelSHA256.isEmpty else {
                    throw FloeBuildingCADError.exportFailed(
                        saved.error ?? "The detail snapshot could not be saved with a verified identity.")
                }
                let identity = FloeBuildingCADNativeIdentity(
                    revision: saved.revision,
                    contentSHA256: saved.contentSHA256,
                    modelSHA256: saved.modelSHA256)
                copy.close()
                try FileManager.default.moveItem(at: staging, to: final)
                guard let readBack = await FloeCADDocument.storedIdentity(at: final),
                      readBack.revision == identity.revision,
                      readBack.contentSHA256 == identity.contentSHA256,
                      readBack.modelSHA256 == identity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The published detail snapshot failed read-back verification.")
                }
                return DetailSnapshot(
                    url: final, relativePath: try relativeSnapshotPath(for: final),
                    identity: identity,
                    removedNonCabinetInstanceIDs: removed,
                    assemblyPage: assemblyPage, explodedPage: explodedPage)
            } catch {
                copy.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: final)
            throw error
        }
    }

    private struct InternalSnapshot {
        var url: URL
        var relativePath: String
        var identity: FloeBuildingCADNativeIdentity
        var removedNonCabinetInstanceIDs: [UUID]
        var page: FloeBuildingCADDetailSheetBuilder.PageResult
    }

    private func createInternalSnapshot(cabinet: FloeBuildingCADCabinetBinding,
                                        assembly: CabinetAssembly,
                                        options: FloeBuildingCADSheetOptions,
                                        sourceIdentity: FloeBuildingCADNativeIdentity,
                                        detailURL: URL,
                                        detailIdentity: FloeBuildingCADNativeIdentity,
                                        detailRelativePath: String,
                                        removedNonCabinetInstanceIDs: [UUID],
                                        previousLayout: [String: FloeBuildingCADDimensionLayout],
                                        migratedAnnotations: [FloeBuildingCADMigratedAnnotation])
        async throws -> InternalSnapshot {
        let snapshots = snapshotDirectory.standardizedFileURL
        let unique = UUID().uuidString
        let staging = snapshots.appendingPathComponent(".staging-\(unique)-internal.floecad",
                                                        isDirectory: true)
        let final = snapshots.appendingPathComponent(
            "Cabinet-\(cabinet.cabinetID.uuidString)-internal-\(unique).floecad",
            isDirectory: true)
        do {
            try FileManager.default.copyItem(at: detailURL, to: staging)
            guard let copiedIdentity = await FloeCADDocument.storedIdentity(at: staging),
                  copiedIdentity.revision == detailIdentity.revision,
                  copiedIdentity.contentSHA256 == detailIdentity.contentSHA256,
                  copiedIdentity.modelSHA256 == detailIdentity.modelSHA256 else {
                throw FloeBuildingCADError.staleBinding(
                    "The copied detail snapshot bytes no longer match the verified source.")
            }
            let copy = try await FloeCADDocument.open(at: staging)
            do {
                let session = FloeBuildingCADSession(document: copy)
                let drawing = CADDrawingService(document: copy)
                let pageIDs = try session.drawingPageIDs()
                for pageID in pageIDs {
                    let removed = drawing.handle(action: "removePage",
                                                 args: ["pageID": pageID.uuidString])
                    guard removed["ok"] as? Bool == true else {
                        throw FloeBuildingCADError.invalidNativeState(
                            removed["message"] as? String ?? "A detail page could not be removed from the internal snapshot.")
                    }
                }
                guard copy.summary().drawingPageCount == 0 else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The internal snapshot still contains unrelated drawing pages.")
                }
                let frontInstanceIDs = Set(cabinet.panelBindings
                    .filter { $0.role == CabinetPanelRole.front.rawValue }
                    .map(\.instanceID))
                let expected = Set(cabinet.panelBindings
                    .filter { $0.role != CabinetPanelRole.front.rawValue }
                    .map(\.instanceID))
                let service = CADAssemblyService(document: copy)
                for instanceID in frontInstanceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let reply = service.handle(action: "removeInstance",
                                               args: ["id": instanceID.uuidString])
                    guard reply["ok"] as? Bool == true else {
                        throw FloeBuildingCADError.invalidNativeState(
                            reply["message"] as? String ?? "A door instance could not be removed from the internal snapshot.")
                    }
                }
                let remaining = try readRootInstanceIDs(service: service)
                guard remaining == expected else {
                    throw FloeBuildingCADError.unsupportedFeature(
                        "The internal snapshot does not contain exactly the non-door cabinet instances.")
                }
                try validatePartialCabinetGeometry(session, cabinet: cabinet,
                                                   excludedInstanceIDs: frontInstanceIDs)
                let builder = FloeBuildingCADDetailSheetBuilder(
                    document: copy, cabinet: cabinet, assembly: assembly, options: options)
                let page = try builder.createInternalPage(
                    previousLayout: previousLayout,
                    migratedAnnotations: migratedAnnotations)
                let saved = await copy.save()
                guard saved.succeeded, !saved.modelSHA256.isEmpty else {
                    throw FloeBuildingCADError.exportFailed(
                        saved.error ?? "The internal snapshot could not be saved with a verified identity.")
                }
                let identity = FloeBuildingCADNativeIdentity(
                    revision: saved.revision,
                    contentSHA256: saved.contentSHA256,
                    modelSHA256: saved.modelSHA256)
                copy.close()
                try FileManager.default.moveItem(at: staging, to: final)
                guard let readBack = await FloeCADDocument.storedIdentity(at: final),
                      readBack.revision == identity.revision,
                      readBack.contentSHA256 == identity.contentSHA256,
                      readBack.modelSHA256 == identity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The published internal snapshot failed read-back verification.")
                }
                return InternalSnapshot(
                    url: final, relativePath: try relativeSnapshotPath(for: final),
                    identity: identity,
                    removedNonCabinetInstanceIDs: removedNonCabinetInstanceIDs,
                    page: page)
            } catch {
                copy.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: final)
            throw error
        }
    }

    // MARK: Snapshot helpers

    func removeNonCabinetRootInstances(document: FloeCADDocument,
                                       panelInstanceIDs: Set<UUID>) throws -> [UUID] {
        let service = CADAssemblyService(document: document)
        var removed: [UUID] = []
        var loop = 0
        while true {
            loop += 1
            guard loop <= 8 else {
                throw FloeBuildingCADError.unsupportedFeature(
                    "The snapshot still contains non-cabinet assembly instances after removal.")
            }
            let reply = service.handle(action: "instances", args: [:])
            guard reply["ok"] as? Bool == true,
                  let rows = reply["instances"] as? [[String: Any]] else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The snapshot assembly instances could not be read.")
            }
            let roots = rows.filter { row in
                let parentRaw = row["parentID"]
                let isRoot = parentRaw == nil || parentRaw is NSNull
                guard isRoot, let id = FloeBuildingCADGeometry.uuid(row["id"]) else { return false }
                return !panelInstanceIDs.contains(id)
            }
            if roots.isEmpty { break }
            for row in roots {
                guard let id = FloeBuildingCADGeometry.uuid(row["id"]) else { continue }
                removed.append(id)
                let reply = service.handle(action: "removeInstance",
                                           args: ["id": id.uuidString])
                guard reply["ok"] as? Bool == true else {
                    throw FloeBuildingCADError.invalidNativeState(
                        reply["message"] as? String ?? "A non-cabinet snapshot instance could not be removed.")
                }
            }
        }
        let remaining = try readRootInstanceIDs(service: service)
        guard remaining == panelInstanceIDs else {
            throw FloeBuildingCADError.unsupportedFeature(
                "The snapshot contains a nested non-cabinet instance or is missing a cabinet panel.")
        }
        return removed
    }

    private func readRootInstanceIDs(service: CADAssemblyService) throws -> Set<UUID> {
        let reply = service.handle(action: "instances", args: [:])
        guard reply["ok"] as? Bool == true,
              let rows = reply["instances"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState(
                reply["message"] as? String ?? "The assembly instances could not be read.")
        }
        var result = Set<UUID>()
        for row in rows {
            let parentRaw = row["parentID"]
            guard parentRaw == nil || parentRaw is NSNull,
                  let id = FloeBuildingCADGeometry.uuid(row["id"]) else { continue }
            result.insert(id)
        }
        return result
    }

    private func validateCabinetBindingInSnapshot(_ snapshot: FloeBuildingCADSession,
                                                  cabinet: FloeBuildingCADCabinetBinding) throws {
        try snapshot.validateCabinetBinding(cabinet)
    }

    /// Validate the non-door panels of a doorless internal snapshot. The full
    /// binding cannot be used because the front panels were intentionally
    /// removed; every remaining panel is still measured through the kernel.
    private func validatePartialCabinetGeometry(_ snapshot: FloeBuildingCADSession,
                                                cabinet: FloeBuildingCADCabinetBinding,
                                                excludedInstanceIDs: Set<UUID>) throws {
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        let panels = Dictionary(uniqueKeysWithValues: assembly.panels.map { ($0.id, $0) })
        let state = try snapshot.nativeState()
        for binding in cabinet.panelBindings where !excludedInstanceIDs.contains(binding.instanceID) {
            guard let panel = panels[binding.panelID] else {
                throw FloeBuildingCADError.invalidBinding("Unknown panel \(binding.panelID).")
            }
            guard let sketch = state.sketches[binding.sketchID],
                  sketch.entities.count == 1,
                  let entity = sketch.entities.first,
                  entity.kind == "rect",
                  let liveMin = entity.minimum,
                  let liveMax = entity.maximum,
                  FloeBuildingCADGeometry.approxEqual(liveMin, binding.sketchRectMin, tolerance: 1e-4),
                  FloeBuildingCADGeometry.approxEqual(liveMax, binding.sketchRectMax, tolerance: 1e-4) else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(binding.panelID): its owned rectangle is missing or edited.")
            }
            let measured = try snapshot.measureNativeBody(binding.bodyID)
            let expected = FloeBuildingCADCabinetRules.worldBounds(panel)
            guard measured.analyticBRep,
                  FloeBuildingCADGeometry.approxEqual(measured.boundsMinimum, expected.minimum,
                                                      tolerance: FloeBuildingCADGeometry.linearToleranceMM),
                  FloeBuildingCADGeometry.approxEqual(measured.boundsMaximum, expected.maximum,
                                                      tolerance: FloeBuildingCADGeometry.linearToleranceMM) else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(binding.panelID): the body bounds no longer match the binding.")
            }
            guard let instance = state.instances[binding.instanceID],
                  instance.bodyID == binding.bodyID,
                  !instance.hidden, instance.parentID == nil else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(binding.panelID): its assembly instance is missing or changed.")
            }
        }
    }

    // MARK: Annotation capture

    /// Capture the CURRENT manual dimension text positions/overrides from a
    /// detail page before it is rebuilt. A user drag/text edit made directly
    /// in the native page is preserved even though the stored binding still
    /// holds the position from page creation.
    func captureDetailLayout(_ detail: FloeBuildingCADDetailSheet) async
        -> [String: FloeBuildingCADDimensionLayout] {
        let fallback = Dictionary(uniqueKeysWithValues: detail.dimensionBindings.map {
            ($0.role, FloeBuildingCADDimensionLayout(
                textPosition: $0.textPosition, textOverride: $0.textOverride))
        })
        guard let document = try? await openDetailSheetRaw(detail) else { return fallback }
        defer { document.close() }
        let geometry = CADDrawingService(document: document).pageGeometry(pageID: detail.pageID)
        guard geometry["ok"] as? Bool == true else { return fallback }
        let rows = geometry["manualDimensions"] as? [[String: Any]] ?? []
        var byID: [UUID: [String: Any]] = [:]
        for row in rows {
            if let id = FloeBuildingCADGeometry.uuid(row["id"]) { byID[id] = row }
        }
        var result: [String: FloeBuildingCADDimensionLayout] = [:]
        for binding in detail.dimensionBindings {
            if let row = byID[binding.dimensionID],
               let position = FloeBuildingCADGeometry.doubleArray(row["localTextPosition"]) {
                result[binding.role] = FloeBuildingCADDimensionLayout(
                    textPosition: position,
                    textOverride: row["textOverride"] as? String ?? binding.textOverride)
            } else {
                result[binding.role] = fallback[binding.role]
                    ?? FloeBuildingCADDimensionLayout(
                        textPosition: binding.textPosition,
                        textOverride: binding.textOverride)
            }
        }
        return result
    }

    func captureDetailAnnotations(_ detail: FloeBuildingCADDetailSheet) async
        -> CapturedDetailAnnotations {
        guard let document = try? await openDetailSheetRaw(detail) else {
            return CapturedDetailAnnotations()
        }
        defer { document.close() }
        let service = CADDrawingService(document: document)
        let geometry = service.pageGeometry(pageID: detail.pageID)
        guard geometry["ok"] as? Bool == true else {
            return CapturedDetailAnnotations()
        }
        let rows = geometry["annotations"] as? [[String: Any]] ?? []
        let views = geometry["views"] as? [[String: Any]] ?? []
        var offsetByView: [UUID: [Double]] = [:]
        for row in views {
            if let id = FloeBuildingCADGeometry.uuid(row["id"]),
               let offset = FloeBuildingCADGeometry.doubleArray(row["offset"]) {
                offsetByView[id] = offset
            }
        }
        let roleByView = Dictionary(uniqueKeysWithValues: detail.viewIDs.map { ($0.value, $0.key) })
        var migrated: [FloeBuildingCADMigratedAnnotation] = []
        var orphaned: [FloeBuildingCADAnnotationBinding] = []
        for row in rows {
            guard let stableID = FloeBuildingCADGeometry.uuid(row["id"]),
                  let text = row["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let binding = row["binding"] as? [String: Any] ?? [:]
            let bound = binding["bound"] as? Bool ?? false
            let viewID = FloeBuildingCADGeometry.uuid(row["viewID"])
            let role = viewID.flatMap { roleByView[$0] }
            var local = FloeBuildingCADGeometry.doubleArray(row["localPosition"])
            if local == nil, let sheetPosition = FloeBuildingCADGeometry.doubleArray(row["position"]) {
                if let viewID, let offset = offsetByView[viewID],
                   offset.count == 2, sheetPosition.count == 2 {
                    local = [sheetPosition[0] - offset[0], sheetPosition[1] - offset[1]]
                } else {
                    local = sheetPosition
                }
            }
            guard !bound, let role, !trimmed.isEmpty, trimmed.count <= 500,
                  let position = local, position.count == 2,
                  position.allSatisfy(\.isFinite) else {
                orphaned.append(FloeBuildingCADAnnotationBinding(
                    stableID: stableID, currentID: nil, viewRole: role,
                    text: trimmed, localPosition: local ?? [], orphaned: true))
                continue
            }
            let height = FloeBuildingCADGeometry.number(row["heightMM"]) ?? 3.5
            migrated.append(FloeBuildingCADMigratedAnnotation(
                stableID: stableID, text: trimmed, localPosition: position,
                heightMM: height, viewRole: role))
        }
        return CapturedDetailAnnotations(migrated: migrated, orphaned: orphaned)
    }

    /// Open a detail snapshot without requiring the stored identity to equal
    /// the old binding. This is the read path used to capture user annotations
    /// before a rebuild; page/scope validation still happens before reuse.
    func openDetailSheetRaw(_ detail: FloeBuildingCADDetailSheet) async throws
        -> FloeCADDocument {
        guard detail.documentScope == "verified-snapshot",
              let path = detail.snapshotRelativePath else {
            throw FloeBuildingCADError.invalidBinding(
                "The detail page is not stored in a verified snapshot.")
        }
        let url = try snapshotURL(for: path)
        guard await FloeCADDocument.storedIdentity(at: url) != nil else {
            throw FloeBuildingCADError.invalidBinding(
                "The detail snapshot package is missing or corrupt.")
        }
        return try await FloeCADDocument.open(at: url)
    }

    /// Open the verified snapshot that owns one detail page. The caller owns
    /// the returned document and must close it.
    func openDetailSheetDocument(_ detail: FloeBuildingCADDetailSheet) async throws
        -> FloeCADDocument {
        guard detail.documentScope == "verified-snapshot",
              let path = detail.snapshotRelativePath else {
            throw FloeBuildingCADError.invalidBinding(
                "The detail page is not stored in a verified snapshot.")
        }
        let url = try snapshotURL(for: path)
        guard let stored = await FloeCADDocument.storedIdentity(at: url) else {
            throw FloeBuildingCADError.invalidBinding(
                "The detail snapshot package is missing or corrupt.")
        }
        if let expected = detail.snapshotIdentity {
            guard stored.revision == expected.revision,
                  stored.contentSHA256 == expected.contentSHA256,
                  stored.modelSHA256 == expected.modelSHA256 else {
                throw FloeBuildingCADError.staleBinding(
                    "The detail snapshot identity does not match the binding.")
            }
        }
        return try await FloeCADDocument.open(at: url)
    }
}

// MARK: - Public session API for detail refresh

public extension FloeBuildingCADSession {
    /// Refresh only the independent detail pages (internal elevation,
    /// assembly, exploded) from a verified saved cabinet. The project page
    /// and manifest are untouched; `refreshCombinationSheet` calls this and
    /// stores the result on the sheet binding.
    @discardableResult
    func refreshDetailSheets(cabinet: FloeBuildingCADCabinetBinding,
                             sheet: FloeBuildingCADSheetBinding) async throws
        -> [FloeBuildingCADDetailSheet] {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        try validateCabinetGeometry(cabinet, assembly: assembly)
        guard sheet.cabinetID == cabinet.cabinetID else {
            throw FloeBuildingCADError.invalidBinding("The sheet belongs to another cabinet.")
        }
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        let sourceIdentity = try await ensureVerifiedSavedIdentity()
        let options = FloeBuildingCADSheetOptions(
            paper: sheet.paper, title: sheet.title,
            includeClearanceDimensions: true, includeThicknessDimensions: true,
            includeCarcassDepthDimension: true,
            manualNotes: sheet.manualNotes,
            includeDetailSheets: true)
        let set = try await makeDetailSheetSet(
            cabinet: cabinet, assembly: assembly, options: options,
            sourceIdentity: sourceIdentity, previous: sheet.detailSheets ?? [])
        return set.sheets
    }

    /// Open the snapshot document for a detail page (read-only ownership by
    /// the caller); used by diagnostics and acceptance hosts.
    func openDetailPageDocument(_ detail: FloeBuildingCADDetailSheet) async throws
        -> FloeCADDocument {
        try await openDetailSheetDocument(detail)
    }
}

/// Remove detail snapshot files created by a failed sheet creation. Only
/// files returned by `makeDetailSheetSet` are passed here; a published file
/// that a binding references is never removed.
func removeDetailFiles(_ urls: [URL]) {
    for url in urls {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
