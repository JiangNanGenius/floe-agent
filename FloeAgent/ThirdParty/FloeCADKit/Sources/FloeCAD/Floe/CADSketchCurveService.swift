// SPDX-License-Identifier: MPL-2.0
// Shared UI/typed-parameter seam. It uses existing document commands,
// ownership, exact OCCT intersection, rebuild and checkpoint/undo services.
import Foundation
import simd

@MainActor
public final class CADSketchCurveService {
    public static let actions = ["trimSketchCurve", "extendSketchCurve", "offsetSketchCurve", "unlinkSketchOffset"]
    private let session: DocumentSession
    private let document: FloeCADDocument?
    public init(document: FloeCADDocument) { self.document = document; session = document.session }
    init(session: DocumentSession) { self.session = session; document = nil }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        do {
            guard Self.actions.contains(action) else { throw fail("unknown_curve_action", "Unknown curve action.") }
            if let block = session.writeBlock { throw fail(block.code, block.message) }
            if let expected = args["expected_change_count"] as? Int, expected != session.changeCount {
                throw fail("revision_mismatch", "The sketch changed. Read it again before editing.")
            }
            if let raw = args["revision"] ?? args["expected_revision"], let document {
                guard let number = CADMaterialService.number(raw), number == Double(document.revision) else {
                    throw fail("revision_mismatch", "The document changed. Read it again before editing.")
                }
            }
            guard let rawSketch = string(args["sketch_id"] ?? args["sketchID"]), let sketchUUID = UUID(uuidString: rawSketch),
                  let sketch = session.document.sketches.first(where: { $0.id.raw == sketchUUID }) else {
                throw fail("unknown_sketch", "Choose an existing sketch.")
            }
            try SketchCurveOffsetKit.validatePlane(sketch.plane)
            var after = sketch
            var response: [String: Any] = ["action": action, "sketch_id": rawSketch]
            let title: String
            if action == "unlinkSketchOffset" {
                guard let raw = string(args["link_id"]), let id = UUID(uuidString: raw),
                      let link = sketch.curveOffsetLinks.first(where: { $0.id == id }) else {
                    throw fail("unknown_curve_offset", "Choose an existing offset relation.")
                }
                after.curveOffsetLinks.removeAll { $0.id == id }
                response["unlinked_id"] = id.uuidString
                response["preserved_entity_ids"] = [link.sourceID.uuidString, link.targetID.uuidString]
                title = "Make Offset Independent"
            } else {
                guard let raw = string(args["entity_id"] ?? args["entityID"]), let id = UUID(uuidString: raw),
                      let index = sketch.entities.firstIndex(where: { $0.id == id }) else {
                    throw fail("unknown_curve", "Choose an existing curve.")
                }
                let source = sketch.entities[index]
                guard sketch.externalReference(forEntityID: id) == nil else {
                    throw fail("external_reference", "Detach the projected curve before trimming, extending or offsetting it.", entities: [id])
                }
                let definition = try SketchCurveDefinition(source)
                if action == "offsetSketchCurve" {
                    guard let distance = CADMaterialService.number(args["distance"]) else {
                        throw fail("missing_offset_distance", "Enter a signed offset distance in millimetres.", entities: [id])
                    }
                    let targetID = UUID()
                    let targetDefinition = try definition.normalOffset(by: distance)
                    let target = try targetDefinition.materialized(id: targetID)
                    after.entities.append(target)
                    if sketch.isConstruction(id) { after.constructionEntityIDs.insert(targetID) }
                    let associative: Bool
                    if let raw = args["associative"] {
                        guard let value = raw as? Bool else { throw fail("invalid_curve_association", "associative must be true or false.") }
                        associative = value
                    } else { associative = true }
                    if associative {
                        let link = try SketchCurveOffsetLink(sourceID: id, targetID: targetID, distance: distance, definition: definition)
                        after.curveOffsetLinks.append(link); response["link_id"] = link.id.uuidString
                    }
                    response["created_entity_ids"] = [targetID.uuidString]
                    response["source_entity_id"] = id.uuidString; response["associative"] = associative
                    response["normal_convention"] = definition.normalOffsetConvention
                    response["distance_mm"] = distance
                    response["definition"] = try json(targetDefinition)
                    title = "Offset Curve"
                } else {
                    try requireIndependentTrimTarget(id, in: sketch)
                    guard let raw = string(args["boundary_id"] ?? args["boundaryID"]), let boundaryID = UUID(uuidString: raw),
                          let boundary = sketch.entities.first(where: { $0.id == boundaryID }) else {
                        throw fail("unknown_curve_boundary", "Choose a boundary in this sketch.", entities: [id])
                    }
                    guard let values = args["pick"] as? [Any], values.count == 2,
                          let x = CADMaterialService.number(values[0]), let y = CADMaterialService.number(values[1]) else {
                        throw fail("invalid_curve_pick", "Pick the part to remove or the endpoint to extend.", entities: [id])
                    }
                    let kind: SketchCurveEditKind = action == "trimSketchCurve" ? .trim : .extend
                    let result = try SketchCurveEditKernel.edit(source, boundary: boundary, pick: SIMD2(x, y), kind: kind)
                    after.entities.replaceSubrange(index...index, with: result.entities)
                    if sketch.isConstruction(id) { after.constructionEntityIDs.formUnion(result.entities.map(\.id)) }
                    response["id_mapping"] = [id.uuidString: result.entities.map { $0.id.uuidString }]
                    response["boundary_id"] = boundaryID.uuidString
                    response["definitions"] = try result.definitions.map { try json($0) }
                    response["removed_constraint_ids"] = [String]()
                    response["removed_dimension_ids"] = [String]()
                    title = kind == .trim ? "Trim Curve" : "Extend Curve"
                }
            }
            after = try SketchCurveOffsetKit.resolve(after)
            guard after != sketch else { throw fail("no_change", "The curve did not change.") }
            let checkpoint = session.captureEditCheckpoint()
            let errors = session.lastEvalErrors
            let command = ReplaceSketchGeometryCommand(title: title, before: sketch, after: after)
            guard session.performWithSketchRebuild(command, sketchID: sketch.id) else {
                throw session.lastCurveEditFailure ?? fail("curve_rebuild_refused", "The curve edit could not be rebuilt. The original is unchanged.")
            }
            let introduced = session.lastEvalErrors.filter { id, error in
                errors[id].map { String(describing: $0) } != String(describing: error)
            }
            if !introduced.isEmpty {
                session.restoreEditCheckpoint(checkpoint)
                throw fail("curve_rebuild_failed", "The curve edit broke a dependent feature and was rolled back.")
            }
            response["ok"] = true; response["mutated"] = true
            response["change_count"] = session.changeCount
            response["can_undo"] = session.undoStack.canUndo; response["can_redo"] = session.undoStack.canRedo
            if let document { response["revision"] = document.revision }
            return response
        } catch let error as SketchCurveEditFailure {
            return ["ok": false, "mutated": false, "error": error.code, "message": error.message,
                    "affected_entity_ids": error.entityIDs.map(\.uuidString),
                    "affected_constraint_ids": error.constraintIDs.map(\.uuidString),
                    "affected_dimension_ids": error.dimensionIDs.map(\.uuidString),
                    "affected_link_ids": error.linkIDs.map(\.uuidString)]
        } catch {
            return ["ok": false, "mutated": false, "error": "curve_edit_failed", "message": "The curve edit failed. The original is unchanged."]
        }
    }

    private func requireIndependentTrimTarget(_ id: UUID, in sketch: Sketch) throws {
        let constraints = sketch.constraints.filter { $0.refs.contains(where: { $0.entityID == id }) }.map(\.id)
        let dimensions = sketch.dimensions.filter { $0.refs.contains(where: { $0.entityID == id }) }.map(\.id)
        let links = SketchCurveOffsetKit.relatedLinks(to: id, in: sketch).map(\.id)
            + sketch.patternLinks.filter { $0.seedIDs.contains(id) || $0.allInstanceIDs.contains(id) }.map(\.id)
        guard constraints.isEmpty, dimensions.isEmpty, links.isEmpty,
              !sketch.disconnectedEndpoints.contains(where: { $0.entityID == id }) else {
            throw SketchCurveEditFailure(code: "curve_edit_references", message: "Release the curve's constraints or links before trimming or extending it. No references were removed.",
                entityIDs: [id], constraintIDs: constraints, dimensionIDs: dimensions, linkIDs: links)
        }
    }
    private func string(_ value: Any?) -> String? { value as? String }
    private func fail(_ code: String, _ message: String, entities: [UUID] = []) -> SketchCurveEditFailure {
        .init(code: code, message: message, entityIDs: entities)
    }
    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
