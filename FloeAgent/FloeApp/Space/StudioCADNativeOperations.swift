// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreFoundation
import FloeCore
import FloeTools
import FloeCAD
import FloeWorkbench

/// The managed original never resolves a path. Known operations use the same
/// native services as the CAD workbenches, under Studio's existing authority.
/// A standalone 2D original only offers sketch/constraint/dimension/curve
/// services; 3D feature/mesh operations remain on the CAD3D original.
@MainActor enum StudioCADNativeOperations {
    enum Service {
        case building, mesh, parameter, curve, constraint
    }
    struct Request {
        let op: String
        let action: String
        let arguments: [String: Any]
        let service: Service
    }
    struct MeasureQuery: Codable, Sendable {
        var kind: String
        var bodyID: UUID? = nil
        var bodyIDs: [UUID]? = nil
        var sketchID: UUID? = nil
        var entityID: UUID? = nil
        var entityIDs: [UUID]? = nil
        var points: [[Double]]? = nil
        var tolerance: Double? = nil
        init(kind: String, bodyID: UUID? = nil, bodyIDs: [UUID]? = nil,
             sketchID: UUID? = nil, entityID: UUID? = nil, entityIDs: [UUID]? = nil,
             points: [[Double]]? = nil, tolerance: Double? = nil) {
            self.kind = kind; self.bodyID = bodyID; self.bodyIDs = bodyIDs
            self.sketchID = sketchID; self.entityID = entityID; self.entityIDs = entityIDs
            self.points = points; self.tolerance = tolerance
        }
        var payload: [String: Any] {
            var value: [String: Any] = ["kind": kind]
            if let bodyID { value["bodyID"] = bodyID.uuidString }
            if let bodyIDs { value["bodyIDs"] = bodyIDs.map(\.uuidString) }
            if let sketchID { value["sketchID"] = sketchID.uuidString }
            if let entityID { value["entityID"] = entityID.uuidString }
            if let entityIDs { value["entityIDs"] = entityIDs.map(\.uuidString) }
            if let points { value["points"] = points }
            if let tolerance { value["tolerance"] = tolerance }
            return value
        }
    }
    struct ReadQuery: Codable, Sendable {
        var sketchID: UUID? = nil
        var sketchOffset: Int = 0
        var sketchLimit: Int = 12
        var entityOffset: Int = 0
        var entityLimit: Int = 80
        var constraintOffset: Int = 0
        var constraintLimit: Int = 120
        var measure: MeasureQuery? = nil
        init() {}
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sketchID = try container.decodeIfPresent(UUID.self, forKey: .sketchID)
            sketchOffset = try container.decodeIfPresent(Int.self, forKey: .sketchOffset) ?? 0
            sketchLimit = try container.decodeIfPresent(Int.self, forKey: .sketchLimit) ?? 12
            entityOffset = try container.decodeIfPresent(Int.self, forKey: .entityOffset) ?? 0
            entityLimit = try container.decodeIfPresent(Int.self, forKey: .entityLimit) ?? 80
            constraintOffset = try container.decodeIfPresent(Int.self, forKey: .constraintOffset) ?? 0
            constraintLimit = try container.decodeIfPresent(Int.self, forKey: .constraintLimit) ?? 120
            measure = try container.decodeIfPresent(MeasureQuery.self, forKey: .measure)
        }
    }

    private static let buildingWrites: Set<String> = ["building.addWall", "building.addRoom"]
    private static var meshWrites: [CadServiceOperationCatalog.Operation] {
        CadServiceOperationCatalog.operations(forKind: "mesh").filter {
            $0.mutating && CADMeshService.advertisedActions.contains($0.action)
        }
    }
    private static let parameterWrites: Set<String> = [
        "updateSketchEntity", "deleteSketchEntity",
        "setSketchDimension", "removeSketchDimension",
        "projectExternalEdges", "detachExternalReferences",
        "sketch.setSupport", "sketch.clearSupport",
        "undo", "redo",
    ]
    private static let constraintWrites: Set<String> = Set(CADSketchEditService.actions)
    private static let curveWrites: Set<String> = Set(CADSketchCurveService.actions)
    private static let sketchWrites: Set<String> = parameterWrites
        .union(constraintWrites).union(curveWrites)
    private static let threeDOnlyGeometry: Set<String> = [
        "feature.extrude", "feature.revolve", "feature.hole", "feature.pattern",
        "feature.mirror", "feature.transform", "feature.boolean", "feature.split",
        "feature.fillet", "feature.chamfer", "feature.shell", "feature.sweep",
        "feature.loft", "feature.pushPull", "feature.moveFace", "feature.deleteFace",
        "feature.replaceFace", "feature.draftFace", "body.setMaterial",
    ]

    static func operationNames(for kind: PersonalContentKind) -> [String] {
        var names = buildingWrites.sorted() + sketchWrites.sorted()
        if kind == .cad3D { names += meshWrites.map(\.op) }
        if kind == .cad2D { names.append("document.importDrawing") }
        return Array(Set(names)).sorted()
    }
    static func contains(_ op: String, kind: PersonalContentKind) -> Bool {
        operationNames(for: kind).contains(op)
    }
    static func geometryOperations(for kind: PersonalContentKind) -> [String] {
        switch kind {
        case .cad2D:
            let offered: Set<String> = ["sketch.create", "sketch.addEntities", "sketch.addText", "item.setHidden"]
            return FloeCADDocument.nativeOperationNames.filter { offered.contains($0) }
        default:
            return FloeCADDocument.nativeOperationNames
        }
    }
    static func threeDOnlyOperations(for kind: PersonalContentKind) -> [String] {
        guard kind == .cad2D else { return [] }
        return FloeCADDocument.nativeOperationNames.filter { threeDOnlyGeometry.contains($0) }.sorted()
    }

    static func resolve(op: String, args: [String: Any], kind: PersonalContentKind) throws -> Request {
        if kind == .cad2D, threeDOnlyGeometry.contains(op) {
            throw invalid("'\(op)' is a 3D feature operation. This standalone 2D original only "
                + "offers sketch, constraint, dimension, curve, measure and drawing export operations; "
                + "no 3D geometry was changed.")
        }
        if buildingWrites.contains(op) {
            let wall: Set<String> = ["name", "a", "b", "thicknessMM", "heightMM"]
            let room: Set<String> = ["name", "min", "max", "heightMM", "wallThicknessMM", "withWalls"]
            let required = op == "building.addWall" ? wall : room
            let allowed = required.union(["storeyID", "baseOffsetMM", "expected_revision", "expected_change_count", "expected_source_sha256"])
            try knownKeys(args, allowed: allowed)
            for key in required where args[key] == nil { throw invalid("\(op) requires args.\(key). Read nativeCAD.nativeServices.building first.") }
            // The native typed decoder and Building service validate geometry,
            // floor ownership, finite dimensions and exact revision pins.
            var arguments = args; arguments["action"] = op
            return Request(op: op, action: op, arguments: arguments, service: .building)
        }
        if let operation = meshWrites.first(where: { $0.op == op }) {
            guard kind == .cad3D else {
                throw invalid("'\(op)' is a 3D mesh operation and is not offered on this 2D original.")
            }
            var allowed = Set(operation.arguments.map(\.name))
            if allowed.contains("bodyID") || allowed.contains("bodyIDs") { allowed.formUnion(["bodyID", "bodyIDs"]) }
            // Exact existing async-service preview-apply pins; preview itself is
            // not an edit in this route and may never trigger a save.
            if ["combine", "boolean", "repair", "simplify"].contains(operation.action) {
                allowed.formUnion(["expectedPreviewHash", "expectedRevision", "expectedChangeCount"])
            }
            try knownKeys(args, allowed: allowed)
            if let preview = args["preview"], (preview as? Bool) != false {
                throw invalid("This studio.edit route applies and saves a native edit. A preview-only request is not a saved edit.")
            }
            for field in operation.arguments {
                let alias: Any? = field.name == "bodyIDs" ? args["bodyID"]
                    : (field.name == "bodyID" && operation.action != "transform" ? args["bodyIDs"] : nil)
                guard let value = args[field.name] else {
                    if field.required && alias == nil { throw invalid("\(op) requires args.\(field.name) (\(field.type)).") }
                    continue
                }
                try validate(value, field: field, op: op)
            }
            return Request(op: op, action: operation.action, arguments: args, service: .mesh)
        }
        if parameterWrites.contains(op) {
            return Request(op: op, action: op, arguments: args, service: .parameter)
        }
        if constraintWrites.contains(op) {
            return Request(op: op, action: op, arguments: args, service: .constraint)
        }
        if curveWrites.contains(op) {
            return Request(op: op, action: op, arguments: args, service: .curve)
        }
        throw invalid("Unsupported managed CAD service operation '\(op)'. Read nativeCAD.nativeOperations; "
            + "inspections are in studio.read and do not save.")
    }

    static func execute(_ request: Request, document: FloeCADDocument) async throws -> [String: Any] {
        var reply: [String: Any]
        switch request.service {
        case .building:
            reply = await CADParameterService(document: document)
                .handleAsync(action: request.action, args: request.arguments)
        case .mesh:
            reply = await CADMeshService(document: document)
                .handleAsync(action: request.action, args: request.arguments)
        case .parameter:
            reply = await CADParameterService(document: document)
                .handleAsync(action: request.action, args: request.arguments)
        case .curve:
            reply = CADSketchCurveService(document: document)
                .handle(action: request.action, args: request.arguments)
        case .constraint:
            reply = CADSketchEditService(document: document)
                .handle(action: request.action, args: request.arguments)
        }
        guard reply["ok"] as? Bool == true else {
            throw invalid("\(request.op): \(reply["error"] as? String ?? "native_service_failed"): "
                + "\(reply["message"] as? String ?? "The native service did not apply this edit.")")
        }
        reply["operation"] = request.op
        return reply
    }

    // MARK: - Bounded state

    static func state(_ document: FloeCADDocument, kind: PersonalContentKind,
                      query: ReadQuery, context: ToolContext) throws -> [String: Any] {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        let snapshot = try JSONSerialization.jsonObject(with: document.snapshotJSON()) as? [String: Any] ?? [:]
        let selection = snapshot["selection"] as? [String] ?? []
        let sketchPage = try page(document, query: [
            "scope": "sketches", "sketchOffset": query.sketchOffset, "sketchLimit": query.sketchLimit,
            "entityOffset": 0, "entityLimit": 1,
        ], context: context)
        var sketches = sketchPage["rows"] as? [[String: Any]] ?? []
        for index in sketches.indices { sketches[index].removeValue(forKey: "entityRows") }
        let firstSketchID = sketches.first?["id"] as? String
        let selectedSketchID = query.sketchID?.uuidString ?? firstSketchID
        var entities: [String: Any] = ["rows": [], "complete": true, "reason": "No sketch exists yet."]
        var constraints: [String: Any] = ["rows": [], "complete": true, "reason": "No sketch exists yet."]
        var selectedSketch: [String: Any] = [:]
        if let selectedSketchID {
            let entityPage = try page(document, query: [
                "scope": "sketches", "sketchID": selectedSketchID, "sketchOffset": 0, "sketchLimit": 1,
                "entityOffset": query.entityOffset, "entityLimit": query.entityLimit,
            ], context: context)
            selectedSketch = (entityPage["rows"] as? [[String: Any]])?.first ?? [:]
            let rows = selectedSketch["entityRows"] as? [[String: Any]] ?? []
            entities = [
                "sketchID": selectedSketchID,
                "offset": selectedSketch["entityOffset"] as? Int ?? query.entityOffset,
                "limit": query.entityLimit,
                "total": selectedSketch["entityTotal"] as? Int ?? rows.count,
                "rows": rows,
                "complete": selectedSketch["entityRowsComplete"] as? Bool ?? true,
                "nextOffset": selectedSketch["nextEntityOffset"] ?? NSNull(),
                "requestNext": "studio.read cad.sketchID=\(selectedSketchID), cad.entityOffset=<nextOffset>, cad.entityLimit<=512",
            ]
            let constraintPage = try page(document, query: [
                "scope": "constraints", "sketchID": selectedSketchID,
                "offset": query.constraintOffset, "limit": query.constraintLimit,
            ], context: context)
            let constraintRows = constraintPage["rows"] as? [[String: Any]] ?? []
            let complete = constraintPage["complete"] as? Bool ?? true
            let constraintNext: Any = complete ? NSNull() : (constraintPage["offset"] as? Int ?? 0) + constraintRows.count
            constraints = [
                "sketchID": selectedSketchID,
                "offset": constraintPage["offset"] as? Int ?? query.constraintOffset,
                "limit": query.constraintLimit,
                "total": constraintPage["total"] as? Int ?? constraintRows.count,
                "rows": constraintRows,
                "complete": complete,
                "nextOffset": constraintNext,
                "requestNext": "studio.read cad.sketchID=\(selectedSketchID), cad.constraintOffset=<nextOffset>, cad.constraintLimit<=500",
            ]
        }
        var result: [String: Any] = [
            "schemaVersion": 2,
            "kind": kind.rawValue,
            "route": "studio.edit with this SAME projectID and fresh expectedRevision; operationsJSON is one {op,args} from nativeOperations",
            "operations": catalog(for: kind, selectedSketch: selectedSketch,
                                  constraints: constraints["rows"] as? [[String: Any]] ?? [],
                                  entities: entities["rows"] as? [[String: Any]] ?? [],
                                  snapshot: snapshot),
            "operationNames": operationNames(for: kind),
            "selection": selection,
            "sketchQuery": [
                "offset": sketchPage["offset"] as? Int ?? query.sketchOffset,
                "limit": query.sketchLimit,
                "total": sketchPage["total"] as? Int ?? sketches.count,
                "sketchesComplete": sketchPage["sketchesComplete"] as? Bool ?? true,
                "sketches": sketches,
                "nextOffset": sketchPage["nextSketchOffset"] ?? NSNull(),
                "requestNext": "studio.read cad.sketchOffset=<nextOffset>, cad.sketchLimit<=50",
            ],
            "sketchID": selectedSketchID ?? NSNull(),
            "entities": entities,
            "constraints": constraints,
            "geometryCheck": kind == .cad2D ? geometryCheck(document) : [
                "route": "Request cad.measure {kind:check} from studio.read for the structural check.",
                "readOnly": true,
            ],
            "measure": measureGuide(selectedSketchID: selectedSketchID,
                                    entities: entities["rows"] as? [[String: Any]] ?? []),
            "unavailable": unavailable(for: kind),
            "exactness": "All ids, counts and measurements come from the live native document graph. "
                + "A read never selects, edits or saves; a successful edit awaits the real document save.",
            "revision": document.revision,
            "changeCount": document.exchangeChangeCount,
            "contentSHA256": document.contentSHA256,
            "hasUnsavedChanges": document.hasUnsavedChanges,
            "canUndo": document.nativeCanUndo,
            "canRedo": document.nativeCanRedo,
        ]
        var services: [String: Any] = ["building": try buildingState(document, context: context)]
        if kind == .cad3D {
            let parameter = CADParameterService(document: document)
            let listed = parameter.handle(action: "list", args: [:])
            guard listed["ok"] as? Bool == true, let features = listed["features"] as? [[String: Any]],
                  features.count <= 4_096 else {
                throw invalid("The current native parameter objects could not be inspected within the read budget.")
            }
            services["parameters"] = ["features": features, "readOnly": true]
            services["mesh"] = try meshState(document, snapshot: snapshot, selection: selection, context: context)
        }
        result["nativeServices"] = services
        if let measure = query.measure {
            let reply = document.nativeMeasureJSON(measure.payload, offset: 0, limit: 64)
            var object = (try? JSONSerialization.jsonObject(with: reply.payload)) as? [String: Any] ?? [:]
            object["ok"] = reply.isOK
            if let error = reply.errorCode { object["error"] = error }
            if let message = reply.message { object["message"] = message }
            result["measureResult"] = object
        }
        let encoded = try JSONSerialization.data(withJSONObject: result)
        guard encoded.count <= 192 * 1_024 else {
            throw invalid("This bounded CAD read page would exceed 192KiB. Request a smaller "
                + "cad.sketchLimit, cad.entityLimit or cad.constraintLimit; nothing was changed.")
        }
        result["inspectionBytes"] = encoded.count
        return result
    }

    private static func page(_ document: FloeCADDocument, query: [String: Any],
                             context: ToolContext) throws -> [String: Any] {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        let reply = document.nativeQueryJSON(query)
        guard reply.isOK,
              let object = try JSONSerialization.jsonObject(with: reply.payload) as? [String: Any] else {
            throw invalid("The current native sketch query could not be read.")
        }
        guard (object["total"] as? Int ?? 0) <= 40_000 else {
            throw invalid("This CAD work exceeds the bounded native sketch inspection budget.")
        }
        return object
    }

    private static func meshState(_ document: FloeCADDocument, snapshot: [String: Any],
                                  selection: [String], context: ToolContext) throws -> [String: Any] {
        var rows: [[String: Any]] = []
        let bodies = snapshot["bodies"] as? [[String: Any]] ?? []
        let ordered = bodies.filter { selection.contains(($0["id"] as? String) ?? "") }
            + bodies.filter { !selection.contains(($0["id"] as? String) ?? "") }
        for body in ordered.prefix(16) {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard let id = body["id"] as? String else { throw invalid("The actual native body identity could not be inspected.") }
            var row = body; row["bodyID"] = id
            if body["brep"] as? Bool == false {
                row["topology"] = CADMeshService(document: document).handle(action: "topology.inspect", args: ["bodyID": id])
            }
            rows.append(row)
        }
        return [
            "schemas": meshWrites.map(schema),
            "bodies": rows,
            "inspectionComplete": ordered.count <= 16,
            "inspectedBodyIDs": rows.compactMap { $0["bodyID"] as? String },
            "remainingBodyIDs": ordered.dropFirst(16).compactMap { $0["id"] as? String },
            "readLimit": 16,
            "readNote": "Body IDs and selection are actual. Topology replies retain their native refusal when the current body has no editable cage; an imported mesh is not a synthetic cage.",
            "exactness": "forceMesh is explicit consent only for a supported destructive mesh rebuild. Transform/material preserve BRep. text/standalone conversion and unknown fields are refused.",
            "meshActionsWithoutManagedSchema": CADMeshService.advertisedActions.filter { action in
                CADServiceOperations.isMutating(kind: "mesh", action: action)
                    && !meshWrites.contains(where: { $0.action == action })
            },
        ]
    }

    private static func geometryCheck(_ document: FloeCADDocument) -> [String: Any] {
        let reply = document.nativeCheckJSON([:])
        let object = (try? JSONSerialization.jsonObject(with: reply.payload)) as? [String: Any] ?? [:]
        let issues = (object["issues"] as? [[String: Any]] ?? []).prefix(32).map { $0 }
        let model = object["model"] as? [String: Any] ?? [:]
        return [
            "issueCount": object["issueCount"] as? Int ?? issues.count,
            "issues": issues,
            "rebuildErrors": (model["rebuildErrors"] as? [[String: Any]] ?? []).prefix(32).map { $0 },
            "bodies": (model["bodies"] as? [[String: Any]] ?? []).count,
            "canUndo": model["canUndo"] as? Bool ?? document.nativeCanUndo,
            "canRedo": model["canRedo"] as? Bool ?? document.nativeCanRedo,
            "complete": (object["issueCount"] as? Int ?? issues.count) <= issues.count,
            "note": "Structural rebuild/mesh check over the actual native graph; no rendered pixel is inspected.",
        ]
    }

    private static func measureGuide(selectedSketchID: String?, entities: [[String: Any]]) -> [String: Any] {
        let entityID = entities.first?["id"] as? String
        var example: [String: Any] = ["kind": "distance", "points": [[0, 0, 0], [0, 0, 0]]]
        if let selectedSketchID, let entityID {
            example = ["kind": "entity", "sketchID": selectedSketchID, "entityID": entityID]
        }
        return [
            "route": "Call studio.read again with cad.measure {kind:...}; its native result is returned in nativeCAD.measureResult. Nothing is mutated or saved.",
            "kinds": ["body", "distance", "bounds", "entity", "angle", "area", "check"],
            "body": ["bodyID": "<actual body id>"],
            "distance": ["points": [["x", "y", "z"], ["x", "y", "z"]]],
            "bounds": ["bodyIDs": ["<actual body id>"]],
            "entity": ["sketchID": selectedSketchID ?? "<actual sketch id>", "entityID": entityID ?? "<actual entity id>"],
            "angle": ["points": [[0, 0], [0, 0], [0, 0]], "orEntityIDs": ["<line>", "<line>"]],
            "area": ["sketchID": selectedSketchID ?? "<actual sketch id>", "entityIDs": ["<closed boundary entity>"]],
            "check": [:],
            "example": example,
            "units": "millimetres; angle values are degrees",
            "readOnly": true,
        ]
    }

    private static func unavailable(for kind: PersonalContentKind) -> [String: Any] {
        if kind == .cad2D {
            return [
                "threeDGeometry": "3D feature/mesh operations are not offered on this standalone 2D original.",
                "layers": "This native document has no user layer system; sketch visibility is item.setHidden. "
                    + "No layer list or layer style command exists to advertise.",
                "constraints": "Symbolic constraints can be added, updated and removed; only driving dimensions are solved at add time, "
                    + "matching the interactive editor.",
                "batchEdit": "The native sketch services edit one entity per command. Repeat the command for multiple "
                    + "entities; no native batch selection mutation exists, so each command keeps its own undo step.",
                "machiningSimulation": "CAM/machining and simulation are separate 3D work routes; a standalone 2D "
                    + "original does not expose them through studio.edit.",
                "drawingPageCreation": "This tool can export an existing saved drawing page. Creating drawing pages/views "
                    + "remains in the CAD editor; no page is invented by the tool.",
            ]
        }
        return ["layerSystem": "No user layer system exists; use native visibility/material operations."]
    }

    // MARK: - Operation catalog

    private struct Hints {
        let sketchID: String?
        let entity: [String: Any]?
        let dimension: [String: Any]?
        let constraint: [String: Any]?
        let body: [String: Any]?
        let revision: Int
    }

    private static func catalog(for kind: PersonalContentKind, selectedSketch: [String: Any],
                                constraints: [[String: Any]], entities: [[String: Any]],
                                snapshot: [String: Any]) -> [[String: Any]] {
        let body = (snapshot["bodies"] as? [[String: Any]])?.first
        let hints = Hints(
            sketchID: selectedSketch["id"] as? String,
            entity: entities.first,
            dimension: constraints.first { $0["isDimension"] as? Bool == true },
            constraint: constraints.first { $0["row_kind"] as? String == "constraint" },
            body: body,
            revision: (snapshot["revision"] as? Int) ?? 0)
        var rows: [[String: Any]] = []
        for op in operationNames(for: kind) {
            if let operation = meshWrites.first(where: { $0.op == op }) {
                rows.append(schema(operation)); continue
            }
            if let operation = buildingOperation(op) {
                rows.append(operation); continue
            }
            let spec = spec(for: op)
            var row: [String: Any] = [
                "op": op, "summary": spec.summary, "mutating": true,
                "args": spec.arguments,
                "exampleIdentity": "Use actual IDs/values from this read. The examples below are "
                    + "illustrative and never a substitute for current state.",
            ]
            if let example = example(for: op, kinds: hints, selectedSketch: selectedSketch) {
                row["example"] = example
            }
            rows.append(row)
        }
        return rows.sorted { ($0["op"] as? String ?? "") < ($1["op"] as? String ?? "") }
    }

    private struct Spec {
        let summary: String
        let arguments: [[String: Any]]
    }
    private static func arg(_ name: String, _ type: String, required: Bool = false, _ note: String = "") -> [String: Any] {
        ["name": name, "type": type, "required": required, "note": note]
    }
    /// Positional optional-field rows use the same typed contract as the
    /// labelled required-field rows; the Boolean is never a description.
    private static func arg(_ name: String, _ type: String, _ required: Bool, _ note: String = "") -> [String: Any] {
        arg(name, type, required: required, note)
    }
    private static func spec(for op: String) -> Spec {
        switch op {
        case "updateSketchEntity":
            return Spec(summary: "Edit exactly one existing line/rect/circle/arc/ellipse/spline by its stable entity id.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("entity_id", "uuid", required: true),
                                    arg("a", "[x,y]", false, "line start; alias start"),
                                    arg("b", "[x,y]", false, "line end; alias end"),
                                    arg("min", "[x,y]", false, "rect lower corner"),
                                    arg("max", "[x,y]", false, "rect upper corner"),
                                    arg("center", "[x,y]", false, "circle/arc/ellipse/polygon centre"),
                                    arg("width", "mm", false, "rect width"),
                                    arg("height", "mm", false, "rect height"),
                                    arg("radius", "mm", false, "circle/arc radius"),
                                    arg("diameter", "mm", false, "circle/arc diameter"),
                                    arg("radius_x", "mm", false, "ellipse X radius"),
                                    arg("radius_y", "mm", false, "ellipse Y radius"),
                                    arg("rotation_deg", "deg", false, "ellipse rotation"),
                                    arg("start_angle_deg", "deg", false, "arc start angle"),
                                    arg("end_angle_deg", "deg", false, "arc end angle"),
                                    arg("sweep_angle_deg", "deg", false, "arc sweep"),
                                    arg("points", "[[x,y]]", false, "spline fit points"),
                                    arg("point_index", "integer", false, "spline point index"),
                                    arg("point", "[x,y]", false, "spline point value"),
                                    arg("expected_*", "number/array", false, "Optional exact current value fences from the entity row; put them directly in args, never nested under fields.")])
        case "deleteSketchEntity":
            return Spec(summary: "Delete exactly one existing sketch entity by stable id in one undo step.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("entity_id", "uuid", required: true),
                                    arg("remove_shared_references", "boolean", false, "Only when a shared constraint/dimension should also be removed."),
                                    arg("remove_pattern_link", "boolean", false, "Only when a pattern link owning this entity should be removed; instances stay.")])
        case "setSketchDimension":
            return Spec(summary: "Create or update one driving dimension (length/angle/radius/diameter/width/height) and solve the sketch.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("kind", "string", required: true),
                                    arg("entity_id", "uuid", false), arg("entity_ids", "[uuid]", false),
                                    arg("value", "number", false), arg("expression", "string", false),
                                    arg("dimension_id", "uuid", false), arg("expected_value", "number", false),
                                    arg("expected_expression", "string", false), arg("refs", "[object]", false)])
        case "removeSketchDimension":
            return Spec(summary: "Remove one driving dimension by id; the relaxed sketch geometry is retained.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("dimension_id", "uuid", required: true)])
        case "addSketchConstraint":
            return Spec(summary: "Add one symbolic geometric constraint to an existing sketch.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("kind", "string", required: true),
                                    arg("refs", "[object]", required: true, "Each {entity_id, role}; role is endpointA|endpointB|center|whole."),
                                    arg("circle_tangency", "string", false, "Only for tangent: externalContact|internalContact.")])
        case "updateSketchConstraint":
            return Spec(summary: "Update one symbolic constraint's kind, refs or circle tangency branch.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("constraint_id", "uuid", required: true),
                                    arg("kind", "string", false), arg("refs", "[object]", false),
                                    arg("circle_tangency", "string", false)])
        case "removeSketchConstraint":
            return Spec(summary: "Remove one symbolic constraint by id in one undo step.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("constraint_id", "uuid", required: true)])
        case "trimSketchCurve", "extendSketchCurve":
            return Spec(summary: op == "trimSketchCurve"
                        ? "Trim one independent sketch curve at an existing boundary and pick point."
                        : "Extend one independent sketch curve to an existing boundary and pick direction.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("entity_id", "uuid", required: true),
                                    arg("boundary_id", "uuid", required: true), arg("pick", "[x,y]", required: true)])
        case "offsetSketchCurve":
            return Spec(summary: "Offset one sketch curve by a signed millimetre distance; optionally keep the source relation.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("entity_id", "uuid", required: true),
                                    arg("distance", "number", required: true), arg("associative", "boolean", false)])
        case "unlinkSketchOffset":
            return Spec(summary: "Make one associative offset target independent while preserving both geometries.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("link_id", "uuid", required: true)])
        case "projectExternalEdges":
            return Spec(summary: "Project exact straight body edges into a sketch as source-linked geometry.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("body_id", "uuid", required: true),
                                    arg("edge_index", "integer", false), arg("edge_indexes", "[integer]", false),
                                    arg("query_token", "string", false, "Current kind=edges generation token."),
                                    arg("edge_midpoints", "[[x,y,z]]", false, "Current midpoints when no current token is used.")])
        case "detachExternalReferences":
            return Spec(summary: "Detach one or more linked projections so their current geometry becomes independent.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("entity_id", "uuid", false),
                                    arg("entity_ids", "[uuid]", false)])
        case "sketch.setSupport":
            return Spec(summary: "Attach an existing sketch to an existing construction plane.",
                        arguments: [arg("sketch_id", "uuid", required: true), arg("plane_id", "uuid", required: true)])
        case "sketch.clearSupport":
            return Spec(summary: "Return an existing sketch to its explicit saved plane.",
                        arguments: [arg("sketch_id", "uuid", required: true)])
        case "undo":
            return Spec(summary: "Undo the newest native document command and save the result.",
                        arguments: [])
        case "redo":
            return Spec(summary: "Redo the newest undone native document command and save the result.",
                        arguments: [])
        case "document.importDrawing":
            return Spec(summary: "Import an authorized task DXF/DWG drawing into the existing 2D sketch as real entities.",
                        arguments: [arg("sketchID", "uuid", required: true),
                                    arg("source", "object", required: true, "{workspacePath, expectedSHA256?} from this saved task."),
                                    arg("placement", "object", false, "{sourceAnchor:[x,y], offsetMM:[x,y], rotationDegrees, unitScaleMM?, acceptOmissions?}"),
                                    arg("format", "string", false, "dxf or dwg; the file extension also decides.")])
        default:
            return Spec(summary: "Native CAD operation.", arguments: [])
        }
    }

    private static func example(for op: String, kinds hints: Hints,
                                selectedSketch: [String: Any]) -> [String: Any]? {
        func wrap(_ args: [String: Any]) -> [String: Any] { ["op": op, "args": args] }
        guard let sketchID = hints.sketchID else {
            switch op {
            case "sketch.create": return wrap(["name": "Sketch"])
            case "sketch.addEntities": return wrap(["sketchID": "<read a sketch first>", "entities": [["kind": "line", "a": [0, 0], "b": [100, 0]]]])
            case "sketch.addText": return wrap(["sketchID": "<read a sketch first>", "text": "Text", "height": 10, "origin": [0, 0]])
            default: return nil
            }
        }
        let entityID = hints.entity?["id"] as? String
        let entityKind = hints.entity?["kind"] as? String
        switch op {
        case "sketch.create":
            return wrap(["name": "Sketch"])
        case "sketch.addEntities":
            return wrap(["sketchID": sketchID, "entities": [["kind": "line", "a": [0, 0], "b": [100, 0]]]])
        case "sketch.addText":
            return wrap(["sketchID": sketchID, "text": "Text", "height": 10, "origin": [0, 0]])
        case "updateSketchEntity":
            guard let entityID, let entity = hints.entity else { return nil }
            var args: [String: Any] = ["sketch_id": sketchID, "entity_id": entityID]
            switch entityKind {
            case "line":
                args["a"] = entity["a"]; args["b"] = entity["b"]
            case "rect":
                args["min"] = entity["min"]; args["max"] = entity["max"]
            case "circle":
                args["center"] = entity["center"]
                args["radius"] = (entity["radius"] as? Double).map { $0 + 1 }
            case "arc":
                args["center"] = entity["center"]
                args["radius"] = (entity["radius"] as? Double).map { $0 + 1 }
            case "ellipse":
                args["center"] = entity["center"]
                args["radius_x"] = (entity["radiusX"] as? Double).map { $0 + 1 }
                args["radius_y"] = entity["radiusY"]
            case "spline":
                guard let points = entity["points"] as? [[Double]], let first = points.first, first.count == 2 else { return nil }
                args["point_index"] = 0; args["point"] = [first[0] + 1, first[1]]
            default: return nil
            }
            return wrap(args)
        case "deleteSketchEntity":
            guard let entityID else { return nil }
            return wrap(["sketch_id": sketchID, "entity_id": entityID])
        case "setSketchDimension":
            if let dimension = hints.dimension, let id = dimension["id"] as? String,
               let kind = dimension["kind"] as? String ?? dimension["dimensionKind"] as? String {
                let value = dimension["display_value"] as? Double ?? 10
                return wrap(["sketch_id": sketchID, "dimension_id": id, "kind": kind, "value": value + 1])
            }
            guard let entityID, let entityKind else { return nil }
            switch entityKind {
            case "line":
                let length = hints.entity?["lengthMM"] as? Double ?? 100
                return wrap(["sketch_id": sketchID, "entity_id": entityID, "kind": "length", "value": length + 1])
            case "circle":
                let radius = hints.entity?["radius"] as? Double ?? 10
                return wrap(["sketch_id": sketchID, "entity_id": entityID, "kind": "radius", "value": radius + 1])
            default: return nil
            }
        case "removeSketchDimension":
            guard let id = hints.dimension?["id"] as? String else { return nil }
            return wrap(["sketch_id": sketchID, "dimension_id": id])
        case "addSketchConstraint":
            guard let entityID, let entityKind else { return nil }
            let ref: [String: Any] = ["entity_id": entityID,
                "role": ["line", "rect"].contains(entityKind) ? "endpointA" : "whole"]
            let kind = ["line", "rect"].contains(entityKind) ? "horizontal" : "fixed"
            return wrap(["sketch_id": sketchID, "kind": kind, "refs": [ref]])
        case "updateSketchConstraint":
            guard let id = hints.constraint?["id"] as? String else { return nil }
            return wrap(["sketch_id": sketchID, "constraint_id": id, "kind": "fixed"])
        case "removeSketchConstraint":
            guard let id = hints.constraint?["id"] as? String else { return nil }
            return wrap(["sketch_id": sketchID, "constraint_id": id])
        case "trimSketchCurve", "extendSketchCurve":
            guard let entityID,
                  let rows = selectedSketch["entityRows"] as? [[String: Any]],
                  let boundary = rows.first(where: { $0["id"] as? String != entityID })?["id"] as? String else { return nil }
            return wrap(["sketch_id": sketchID, "entity_id": entityID, "boundary_id": boundary, "pick": [0, 0]])
        case "offsetSketchCurve":
            guard let entityID else { return nil }
            return wrap(["sketch_id": sketchID, "entity_id": entityID, "distance": 5, "associative": true])
        case "unlinkSketchOffset":
            guard let rows = selectedSketch["entityRows"] as? [[String: Any]] else { return nil }
            let links = rows.flatMap { ($0["curve_offset_links"] as? [[String: Any]]) ?? [] }
            guard let link = links.first(where: { $0["id"] is String })?["id"] as? String else { return nil }
            return wrap(["sketch_id": sketchID, "link_id": link])
        case "detachExternalReferences":
            guard let entityID else { return nil }
            return wrap(["sketch_id": sketchID, "entity_id": entityID])
        case "sketch.setSupport":
            guard let plane = selectedSketch["support"] as? [String: Any],
                  let id = plane["planeID"] as? String ?? plane["id"] as? String else { return nil }
            return wrap(["sketch_id": sketchID, "plane_id": id])
        case "sketch.clearSupport":
            return wrap(["sketch_id": sketchID])
        case "undo", "redo":
            return wrap([:])
        case "document.importDrawing":
            return wrap(["sketchID": sketchID,
                         "source": ["workspacePath": "Attachments/<authorized-file>/drawing.dxf"],
                         "placement": ["sourceAnchor": [0, 0], "offsetMM": [0, 0], "rotationDegrees": 0]])
        default:
            return nil
        }
    }

    private static func buildingOperation(_ op: String) -> [String: Any]? {
        guard buildingWrites.contains(op) else { return nil }
        let isWall = op == "building.addWall"
        return [
            "op": op, "summary": isWall ? "Add a straight wall to the existing Building floor." : "Add a rectangular room with walls.",
            "mutating": true,
            "args": isWall
                ? [arg("name", "string", required: true), arg("a", "[x,y]", required: true), arg("b", "[x,y]", required: true),
                   arg("thicknessMM", "mm", required: true), arg("heightMM", "mm", required: true),
                   arg("storeyID", "uuid", false), arg("baseOffsetMM", "mm", false),
                   arg("expected_revision", "integer", required: true), arg("expected_change_count", "integer", required: true),
                   arg("expected_source_sha256", "sha256", required: true)]
                : [arg("name", "string", required: true), arg("min", "[x,y]", required: true), arg("max", "[x,y]", required: true),
                   arg("heightMM", "mm", required: true), arg("wallThicknessMM", "mm", required: true),
                   arg("withWalls", "boolean", false), arg("storeyID", "uuid", false),
                   arg("expected_revision", "integer", required: true), arg("expected_change_count", "integer", required: true),
                   arg("expected_source_sha256", "sha256", required: true)],
            "exampleIdentity": "Use the actual pins and storey id from nativeServices.building.examples.",
        ]
    }
    private static func schema(_ operation: CadServiceOperationCatalog.Operation) -> [String: Any] {
        ["op": operation.op, "summary": operation.summary, "mutating": true,
         "args": operation.arguments.map { ["name": $0.name, "type": $0.type, "required": $0.required, "note": $0.note] as [String: Any] },
         "examples": operation.examples.filter { !$0.contains("\"preview\":true") }.map { "{\"op\":\"\(operation.op)\",\"args\":\($0)}" },
         "exampleIdentity": "Angle-bracket UUID examples are schema placeholders. Use an actual existing body/feature/cage ID from this saved work.",
         "preview": "Preview-only requests are not edits and are refused by this managed edit route."]
    }

    private static func buildingState(_ document: FloeCADDocument, context: ToolContext) throws -> [String: Any] {
        let service = CADParameterService(document: document)
        var floorOffset = 0, elementOffset = 0, floors: [[String: Any]] = [], elements: [[String: Any]] = []
        var first: [String: Any] = [:]
        for page in 0..<72 {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let reply = service.handle(action: "building.inspect", args: ["storeyOffset": floorOffset, "elementOffset": elementOffset, "limit": 16])
            guard reply["ok"] as? Bool == true, let rows = reply["elements"] as? [[String: Any]],
                  let storeys = reply["storeys"] as? [[String: Any]] else {
                throw invalid("The existing building could not be inspected.")
            }
            if page == 0 { first = reply }
            floors += storeys; elements += rows
            guard floors.count <= 128, elements.count <= 1_000 else { throw invalid("Building inspection exceeds its native object budget.") }
            let nextFloor = reply["nextStoreyOffset"] as? Int, nextElement = reply["nextElementOffset"] as? Int
            if nextFloor == nil && nextElement == nil { break }
            floorOffset = nextFloor ?? ((reply["storeyCount"] as? Int) ?? floors.count)
            elementOffset = nextElement ?? ((reply["elementCount"] as? Int) ?? elements.count)
            if page == 71 { throw invalid("Building pagination did not finish within its native object budget.") }
        }
        first["storeys"] = floors; first["elements"] = elements
        first.removeValue(forKey: "nextStoreyOffset"); first.removeValue(forKey: "nextElementOffset")
        var catalog = CADBuildingToolService.catalogObject()
        catalog["route"] = "studio.read nativeCAD.nativeServices.building; studio.edit operationsJSON={op:building.addWall|building.addRoom,args:{...}} with the same projectID"
        catalog["examplePins"] = "Use expected_revision, expected_change_count and expected_source_sha256 from this actual building inspection, plus studio.read expectedRevision. Never guess a file path."
        let pins: [String: Any] = ["expected_revision": document.revision, "expected_change_count": document.buildingChangeCount,
            "expected_source_sha256": document.contentSHA256]
        var wall: [String: Any] = ["name": "Wall A", "a": [0,0], "b": [4000,0], "thicknessMM": 200, "heightMM": 3000]
        var room: [String: Any] = ["name": "Room A", "min": [5000,0], "max": [9000,3000], "heightMM": 3000, "wallThicknessMM": 200, "withWalls": true]
        wall.merge(pins) { _, fresh in fresh }; room.merge(pins) { _, fresh in fresh }
        if floors.count == 1, let id = floors.first?["id"] { wall["storeyID"] = id; room["storeyID"] = id }
        catalog["examples"] = [["op": "building.addWall", "args": wall], ["op": "building.addRoom", "args": room]]
        first["catalog"] = catalog; first["complete"] = true
        return first
    }

    private static func knownKeys(_ args: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(args.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw invalid("Unsupported native CAD fields: \(unknown.sorted().joined(separator: ", ")). No supplied field was applied.") }
    }
    private static func validate(_ value: Any, field: CadServiceOperationCatalog.Argument, op: String) throws {
        func number(_ value: Any) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        let valid: Bool
        switch field.type {
        case "uuid": valid = (value as? String).flatMap(UUID.init(uuidString:)) != nil
        case "[uuid]": valid = (value as? [String]).map { !$0.isEmpty && $0.count <= 4_096 && $0.allSatisfy { UUID(uuidString: $0) != nil } } ?? false
        case "integer": valid = number(value).map { $0.rounded() == $0 } ?? false
        case "number", "mm": valid = number(value) != nil
        case "[x,y,z]": valid = (value as? [Any]).map { $0.count == 3 && $0.allSatisfy { number($0) != nil } } ?? false
        case "boolean": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "sha256": valid = (value as? String).map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) } } ?? false
        case "string": valid = value is String
        case "object": valid = value is [String: Any]
        default: valid = true // Enum/compound geometry uses the typed native validator.
        }
        guard valid else { throw invalid("\(op) args.\(field.name) must be \(field.type).") }
    }
    private static func invalid(_ text: String) -> FloeError { .validationFailed(text) }
}
#endif
