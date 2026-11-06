// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// Replace the building-owned graph slice at its original position. Unrelated
/// CAD features retain order and identity; downstream references are validated
/// by the existing whole-document rebuild before anything commits.
struct SetBuildingFeaturesCommand: DocumentCommand {
    let title = "Building"
    let before: FeatureGraph
    let after: FeatureGraph
    func apply(to document: inout DesignDocument) { document.features = after }
    func revert(in document: inout DesignDocument) { document.features = before }
}

nonisolated enum CADBuildingGeometry {
    static func recipe(_ model: CADBuildingDocument) throws -> [FeatureNode] {
        try model.validate()
        var nodes: [FeatureNode] = []
        func primitive(_ element: CADBuildingElement, role: String = "shape", name: String? = nil,
                       spec: PrimitiveSpec, at centre: SIMD3<Double>, rotation: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0,1,0)),
                       bodyID: UUID? = nil) -> FeatureNode {
            var placement = Transform3D(); placement.translation = centre; placement.rotation = rotation
            return FeatureNode(id: FeatureID(raw: CADBuildingIdentity.uuid(element.id, role)),
                name: name ?? element.name, kind: .primitive(spec: spec, placement: placement),
                outputBodyIDs: [BodyID(raw: bodyID ?? element.bodyID)])
        }
        func point(_ a: [Double], elevation: Double) -> SIMD3<Double> { SIMD3(a[0], elevation, -a[1]) }
        for element in model.elements where ![.door, .window, .space].contains(element.kind) {
            let floor = model.storeys.first { $0.id == element.storeyID }!
            let elevation = floor.elevationMM + element.baseOffsetMM
            let midpoint = [(element.a[0]+element.b[0])/2, (element.a[1]+element.b[1])/2]
            let angle = atan2(element.b[1]-element.a[1], element.b[0]-element.a[0])
            let rotation = simd_quatd(angle: angle, axis: SIMD3(0,1,0))
            switch element.kind {
            case .slab, .roof:
                nodes.append(primitive(element, spec: .box(width: abs(element.b[0]-element.a[0]),
                    depth: abs(element.b[1]-element.a[1]), height: element.thicknessMM), at: point(midpoint,elevation: elevation)))
            case .column:
                nodes.append(primitive(element, spec: .box(width: element.thicknessMM, depth: element.thicknessMM,
                    height: element.heightMM), at: point(element.a,elevation: elevation)))
            case .stair:
                let count = element.stepCount ?? 12, run = element.lengthMM / Double(count)
                for index in 0..<count {
                    let t = (Double(index)+0.5)/Double(count)
                    let centre = [element.a[0]+(element.b[0]-element.a[0])*t, element.a[1]+(element.b[1]-element.a[1])*t]
                    nodes.append(primitive(element, role: "step-\(index)", spec: .box(width: run,
                        depth: element.thicknessMM, height: element.heightMM * Double(index+1)/Double(count)),
                        at: point(centre,elevation: elevation), rotation: rotation,
                        bodyID: index == 0 ? element.bodyID : CADBuildingIdentity.uuid(element.id,"step-body-\(index)")))
                }
            case .pipe:
                let direction = SIMD3(element.b[0]-element.a[0], 0, -(element.b[1]-element.a[1]))
                nodes.append(primitive(element, spec: .cylinder(radius: element.thicknessMM/2, height: element.lengthMM),
                    at: point(element.a,elevation: elevation), rotation: simd_quatd(from: SIMD3(0,1,0), to: simd_normalize(direction))))
            default:
                let node = primitive(element, spec: .box(width: element.lengthMM, depth: element.thicknessMM,
                    height: element.heightMM), at: point(midpoint,elevation: elevation), rotation: rotation)
                nodes.append(node)
                if element.kind == .wall {
                    var producer = node.id
                    let openings = model.elements.filter { $0.hostID == element.id }.sorted { $0.id.uuidString < $1.id.uuidString }
                    for opening in openings {
                        let t = (opening.offsetMM! + opening.widthMM!/2) / element.lengthMM
                        let centre = [element.a[0]+(element.b[0]-element.a[0])*t, element.a[1]+(element.b[1]-element.a[1])*t]
                        let toolID = CADBuildingIdentity.uuid(opening.id,"opening-tool-body")
                        let tool = primitive(opening, role: "opening-tool", name: opening.name,
                            spec: .box(width: opening.widthMM!, depth: element.thicknessMM+2, height: opening.heightMM),
                            at: point(centre,elevation: floor.elevationMM+element.baseOffsetMM+opening.baseOffsetMM),
                            rotation: rotation, bodyID: toolID)
                        nodes.append(tool)
                        let cut = FeatureNode(id: FeatureID(raw: CADBuildingIdentity.uuid(opening.id,"opening-cut")),
                            name: opening.name, kind: .boolean(kind: .subtract,
                                target: BodyRef(producer: producer,bodyID: BodyID(raw:element.bodyID)),
                                tools: [BodyRef(producer: tool.id,bodyID: BodyID(raw:toolID))]),
                            outputBodyIDs: [BodyID(raw:element.bodyID)])
                        nodes.append(cut); producer = cut.id
                        // A thin leaf/glazing is independently selectable; the
                        // opening is a real subtraction in its host wall.
                        nodes.append(primitive(opening, spec: .box(width: opening.widthMM!-0.5,
                            depth: min(element.thicknessMM, opening.thicknessMM), height: opening.heightMM-0.5),
                            at: point(centre,elevation: floor.elevationMM+element.baseOffsetMM+opening.baseOffsetMM+0.25), rotation:rotation))
                    }
                }
            }
        }
        return nodes
    }
}

@MainActor
public extension FloeCADDocument {
    func building() throws -> CADBuildingDocument? { try CADBuildingDocument.decode(session.document.buildingData) }

    /// CAS protects an inspector opened before another tool changed the model.
    /// Geometry and semantic metadata are ONE undoable document transaction.
    @discardableResult
    func setBuilding(_ model: CADBuildingDocument, expectedChangeCount: Int? = nil) throws -> CADBuildingDocument {
        guard !isClosed, !isReadOnly, session.writeBlock == nil else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.thisDocumentCannotBeEdited","This document cannot be edited.")) }
        if let expectedChangeCount, expectedChangeCount != session.changeCount { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.theDesignChangedReopenTheBuildingSettings","The design changed. Reopen the building settings.")) }
        guard session.document.features.rollbackIndex == nil else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.returnHistoryToTheLatestFeatureBefore","Return history to the latest feature before editing the building.")) }
        let data = try model.encoded(), previous = try building()
        if data == session.document.buildingData { return model }
        let before = session.document.features
        let previousRecipe = try previous.map { try CADBuildingGeometry.recipe($0) } ?? []
        let oldIDs = Set(previousRecipe.map(\.id))
        let replacement = try CADBuildingGeometry.recipe(model)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        func sameRecipe(_ a:[FeatureNode],_ b:[FeatureNode]) throws -> Bool {
            guard a.map(\.id) == b.map(\.id) else { return false }
            for (left,right) in zip(a,b) {
                if try encoder.encode(left.kind) != encoder.encode(right.kind) { return false }
            }
            return true
        }
        if previous != nil, try sameRecipe(previousRecipe,replacement) {
            // Floor names, rules and other metadata do not rebuild or reset a
            // deliberate CAD edit to the already authored geometry.
            let count=session.changeCount
            session.perform(SetBuildingDataCommand(before:session.document.buildingData,after:data))
            guard session.changeCount != count else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.theBuildingSettingsCouldNotBeApplied","The building settings could not be applied.")) }
            return model
        }
        if previous != nil {
            let existing=before.nodes.filter { oldIDs.contains($0.id) }
            guard try sameRecipe(previousRecipe,existing) else {
                throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.buildingGeometryWasChangedInCADRestore","Building geometry was changed in CAD. Restore its building features before changing these dimensions."))
            }
        }
        let newIDs = Set(replacement.map(\.id))
        let ownedIndices = before.nodes.indices.filter { oldIDs.contains(before.nodes[$0].id) }
        if let first = ownedIndices.first, let last = ownedIndices.last,
           last-first+1 != ownedIndices.count {
            throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.buildingFeaturesHaveBeenInterleavedWithOther","Building features have been interleaved with other CAD features. Restore their history order before editing the building."))
        }
        guard Set(before.nodes.filter { !oldIDs.contains($0.id) }.map(\.id)).isDisjoint(with: newIDs) else {
            throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.aBuildingFeatureIdentityConflictsWithAnother","A building feature identity conflicts with another feature."))
        }
        let anchor = before.nodes.firstIndex { oldIDs.contains($0.id) } ?? before.nodes.count
        var after = before
        after.nodes.removeAll { oldIDs.contains($0.id) }
        after.nodes.insert(contentsOf: replacement, at: min(anchor,after.nodes.count))
        guard session.performAssociativeTransaction([
            SetBuildingFeaturesCommand(before:before,after:after),
            SetBuildingDataCommand(before:session.document.buildingData,after:data)
        ], title: FloeCADStrings.text("cad.building.edit", "Edit building"), strictValidation:true) else {
            throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.theBuildingCouldNotBeRebuiltThe","The building could not be rebuilt. The previous model was kept."))
        }
        return model
    }
    var buildingChangeCount: Int { session.changeCount }

    /// Selected line work is explicitly interpreted as wall CENTRE lines.
    /// Arcs, circles and omitted entities remain source evidence, never silently
    /// flattened into walls. The UI previews this candidate before committing.
    func buildingCandidate(from transfer: CADSketchTransferEnvelope, storeyID: UUID? = nil,
                           unitScaleMM: Double? = nil, wallThicknessMM: Double = 200,
                           wallHeightMM: Double = 3000, acceptUnsupported: Bool = false) throws -> CADBuildingDocument {
        try transfer.validate()
        guard transfer.purpose == .buildingFloorplan else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.chooseTheBuildingFloorPlanTransfer","Choose the building floor-plan transfer.")) }
        let scale = unitScaleMM ?? transfer.placement?.unitScaleMM ?? transfer.snapshot.unitScaleMM
        guard let scale, scale.isFinite, scale > 0 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.chooseTheDrawingUnitBeforeImportingThis","Choose the drawing unit before importing this floor plan.")) }
        let unsupported = transfer.snapshot.curves.filter { $0.kind != .line }.count + transfer.snapshot.omissions.count
        guard unsupported == 0 || acceptUnsupported else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.thisSelectionContainsCurvesOrUnsupportedObjects","This selection contains curves or unsupported objects. Review them before importing straight wall lines.")) }
        let current = try building()
        var model = current ?? CADBuildingDocument(name:name)
        if current == nil, let storeyID { model.storeys[0].id = storeyID }
        let floorID = storeyID ?? model.storeys[0].id
        guard model.storeys.contains(where: { $0.id == floorID }) else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.chooseACurrentBuildingFloor","Choose a current building floor.")) }
        let placement = transfer.placement ?? CADSketchTransferPlacement(target:.top)
        guard placement.target == .top else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.chooseTheTopPlaneForABuilding","Choose the top plane for a building floor plan.")) }
        let radians = placement.rotationDegrees * .pi / 180
        func point(_ raw: [Double]) -> [Double] {
            let x=(raw[0]-placement.sourceAnchor[0])*scale, y=(raw[1]-placement.sourceAnchor[1])*scale
            return [x*cos(radians)-y*sin(radians)+placement.offsetMM[0], x*sin(radians)+y*cos(radians)+placement.offsetMM[1]]
        }
        let lines = transfer.snapshot.curves.filter { $0.kind == .line }
        guard !lines.isEmpty, lines.count <= 256 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.select1256StraightWallCentreLines","Select 1–256 straight wall centre lines for one import.")) }
        let existingCount = model.elements.count
        for (index,line) in lines.enumerated() {
            var element = CADBuildingElement(storeyID:floorID,kind:.wall,name:"Wall \(existingCount+index+1)",
                a:point(line.start!),b:point(line.end!),thicknessMM:wallThicknessMM,heightMM:wallHeightMM)
            element.sourceHandle = line.handle; model.elements.append(element)
        }
        if !model.sources.contains(where: { $0.sourceSHA256 == transfer.sourceSHA256 && $0.snapshot == transfer.snapshot }) {
            model.sources.append(transfer)
        }
        try model.validate(); return model
    }

    /// Native drawing service is shared with the mechanical workbench. Its
    /// DWG export hook remains document-scoped and performs real write/readback.
    func createBuildingDrawing(storeyID: UUID? = nil) throws -> [String: Any] {
        guard let model = try building() else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.createOrImportABuildingFirst","Create or import a building first.")) }
        let elements = model.elements.filter { storeyID == nil || $0.storeyID == storeyID }
        let wanted = Set(elements.flatMap(\.bodyIDs))
        let ids = session.document.bodies.filter { wanted.contains($0.id.raw) }.map { $0.id.raw.uuidString }
        guard !ids.isEmpty else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.thisFloorHasNoVisibleModelGeometry","This floor has no visible model geometry to draw.")) }
        guard ids.count <= CADDrawingService.maxSourceBodies else {
            throw CADBuildingError.invalid(FloeCADStrings.format("cad.building.drawingLimit",
                "Choose up to %d source bodies per page in Drawings.",CADDrawingService.maxSourceBodies))
        }
        let result = CADDrawingService(document:self).handle(action:"multiViewSheet",args:["bodyIDs":ids,"title":model.name])
        guard result["ok"] as? Bool == true else { throw CADBuildingError.invalid(result["message"] as? String ?? "The drawing could not be created.") }
        return result
    }
}
