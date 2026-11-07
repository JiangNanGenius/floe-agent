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
@MainActor enum StudioCADNativeOperations {
    private static let buildingWrites: Set<String> = ["building.addWall", "building.addRoom"]
    private static var meshWrites: [CadServiceOperationCatalog.Operation] {
        CadServiceOperationCatalog.operations(forKind: "mesh").filter {
            $0.mutating && CADMeshService.advertisedActions.contains($0.action)
        }
    }
    static var operationNames: [String] { buildingWrites.sorted() + meshWrites.map(\.op) }
    static func contains(_ op: String) -> Bool { operationNames.contains(op) }

    struct Request {
        let op: String
        let action: String
        let arguments: [String: Any]
        let building: Bool
    }
    static func resolve(op: String, args: [String: Any]) throws -> Request {
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
            return Request(op: op, action: op, arguments: arguments, building: true)
        }
        guard let operation = meshWrites.first(where: { $0.op == op }) else {
            throw invalid("Unsupported managed CAD service operation '\(op)'. Read nativeCAD.nativeOperations; inspections are in studio.read and do not save.")
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
        return Request(op: op, action: operation.action, arguments: args, building: false)
    }
    static func execute(_ request: Request, document: FloeCADDocument) async throws -> [String: Any] {
        var reply = request.building
            ? await CADParameterService(document: document).handleAsync(action: request.action, args: request.arguments)
            : await CADMeshService(document: document).handleAsync(action: request.action, args: request.arguments)
        guard reply["ok"] as? Bool == true else {
            throw invalid("\(request.op): \(reply["error"] as? String ?? "native_service_failed"): \(reply["message"] as? String ?? "The native service did not apply this edit.")")
        }
        reply["operation"] = request.op
        return reply
    }

    static func state(_ document: FloeCADDocument, context: ToolContext) throws -> [String: Any] {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        let parameter = CADParameterService(document: document)
        let listed = parameter.handle(action: "list", args: [:])
        guard listed["ok"] as? Bool == true, let features = listed["features"] as? [[String: Any]], features.count <= 4_096 else {
            throw invalid("The current native parameter objects could not be inspected within the read budget.")
        }
        let snapshot = try JSONSerialization.jsonObject(with: document.snapshotJSON()) as? [String: Any] ?? [:]
        let selection = snapshot["selection"] as? [String] ?? []
        let building = try buildingState(document, context: context)
        var meshRows: [[String: Any]] = []
        let bodies = snapshot["bodies"] as? [[String: Any]] ?? []
        // The read bounds expensive cage evaluation separately from the full
        // body identity list already present in the native snapshot.
        let ordered = bodies.filter { selection.contains(($0["id"] as? String) ?? "") }
            + bodies.filter { !selection.contains(($0["id"] as? String) ?? "") }
        for body in ordered.prefix(16) {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard let id = body["id"] as? String else { throw invalid("The actual native body identity could not be inspected.") }
            var row = body; row["bodyID"] = id
            if body["brep"] as? Bool == false {
                row["topology"] = CADMeshService(document: document).handle(action: "topology.inspect", args: ["bodyID": id])
            }
            meshRows.append(row)
        }
        var result: [String: Any] = [
            "schemaVersion": 1,
            "route": "studio.edit with this SAME projectID and fresh expectedRevision; operationsJSON is one {op,args} from nativeOperations",
            "operations": operationNames,
            "selection": selection,
            "parameters": ["features": features, "readOnly": true, "note": "Actual existing feature/parameter IDs and values. This first managed service batch does not add a parameter.update command."],
            "building": building,
            "mesh": ["schemas": meshWrites.map(schema), "bodies": meshRows,
                "inspectionComplete": ordered.count <= 16, "inspectedBodyIDs": meshRows.compactMap { $0["bodyID"] as? String },
                "remainingBodyIDs": ordered.dropFirst(16).compactMap { $0["id"] as? String },
                "readLimit": 16,
                "readNote": "Body IDs and selection are actual. Topology replies retain their native refusal when the current body has no editable cage; an imported mesh is not a synthetic cage.",
                "exactness": "forceMesh is explicit consent only for a supported destructive mesh rebuild. Transform/material preserve BRep. text/standalone conversion and unknown fields are refused."],
            "unavailable": ["standalone forceMesh conversion", "mesh.text", "parameter mutation route", "managed local-render route"],
            "meshActionsWithoutManagedSchema": CADMeshService.advertisedActions.filter { action in
                CADServiceOperations.isMutating(kind: "mesh", action: action) && !meshWrites.contains(where: { $0.action == action })
            },
        ]
        let encoded = try JSONSerialization.data(withJSONObject: result)
        guard encoded.count <= 24 * 1_024 * 1_024 else { throw invalid("The native service inspection exceeds the 24MiB read budget.") }
        result["inspectionBytes"] = encoded.count
        return result
    }
    private static func buildingState(_ document: FloeCADDocument, context: ToolContext) throws -> [String: Any] {
        let service = CADParameterService(document: document)
        var floorOffset = 0, elementOffset = 0, floors: [[String: Any]] = [], elements: [[String: Any]] = []
        var first: [String: Any] = [:]
        for page in 0..<72 {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let reply = service.handle(action: "building.inspect", args: ["storeyOffset": floorOffset, "elementOffset": elementOffset, "limit": 16])
            guard reply["ok"] as? Bool == true, let rows = reply["elements"] as? [[String: Any]],
                  let storeys = reply["storeys"] as? [[String: Any]] else { throw invalid("The existing building could not be inspected.") }
            if page == 0 { first = reply }
            floors += storeys; elements += rows
            guard floors.count <= 128, elements.count <= 1_000 else { throw invalid("Building inspection exceeds its native object budget.") }
            let nextFloor = reply["nextStoreyOffset"] as? Int, nextElement = reply["nextElementOffset"] as? Int
            if nextFloor == nil && nextElement == nil { break }
            // Exhausted collections stay exhausted while the other page advances.
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
    private static func schema(_ operation: CadServiceOperationCatalog.Operation) -> [String: Any] {
        ["op": operation.op, "summary": operation.summary, "mutating": true,
         "args": operation.arguments.map { ["name": $0.name, "type": $0.type, "required": $0.required, "note": $0.note] as [String: Any] },
         "examples": operation.examples.filter { !$0.contains("\"preview\":true") }.map { "{\"op\":\"\(operation.op)\",\"args\":\($0)}" },
         "exampleIdentity": "Angle-bracket UUID examples are schema placeholders. Use an actual existing body/feature/cage ID from this saved work.",
         "preview": "Preview-only requests are not edits and are refused by this managed edit route."]
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
