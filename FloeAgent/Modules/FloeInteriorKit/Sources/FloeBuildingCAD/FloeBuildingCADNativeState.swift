// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

struct FloeBuildingCADFeatureRow {
    var id: UUID
    var kind: String
    var suppressed: Bool
    var referencedSketches: [UUID]
    var bodyIDs: Set<UUID>
    var outputBodyIDs: Set<UUID>
}

struct FloeBuildingCADEntityRow {
    var id: UUID
    var kind: String
    var minimum: [Double]?
    var maximum: [Double]?
}

struct FloeBuildingCADSketchRow {
    var id: UUID
    var entities: [FloeBuildingCADEntityRow]
}

struct FloeBuildingCADInstanceRow {
    var id: UUID
    var name: String
    var bodyID: UUID
    var effectiveBodyID: UUID?
    var hidden: Bool
    var isSubassembly: Bool
    var parentID: UUID?
    var position: [Double]
    var rotation: [Double]
    var scale: [Double]
}

struct FloeBuildingCADMeasurement {
    var boundsMinimum: [Double]
    var boundsMaximum: [Double]
    var volumeMM3: Double
    var analyticBRep: Bool
}

struct FloeBuildingCADNativeState {
    var features: [UUID: FloeBuildingCADFeatureRow]
    var sketches: [UUID: FloeBuildingCADSketchRow]
    var instances: [UUID: FloeBuildingCADInstanceRow]
}

extension FloeBuildingCADSession {
    func executeNative(_ operation: String, _ args: [String: Any]) throws -> [String: Any] {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let outcome = document.execute(["op": operation, "args": args])
        guard outcome.isOK,
              let object = FloeBuildingCADGeometry.object(outcome) else {
            throw FloeBuildingCADError.invalidNativeState(
                "\(operation): \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")")
        }
        return object
    }

    func nativeState() throws -> FloeBuildingCADNativeState {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let featuresOutcome = document.nativeQueryJSON(
            ["scope": "features", "limit": 500])
        guard featuresOutcome.isOK,
              let featuresPayload = FloeBuildingCADGeometry.object(featuresOutcome),
              let featureRows = featuresPayload["rows"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState(
                featuresOutcome.message ?? "The native feature list could not be read.")
        }
        var features: [UUID: FloeBuildingCADFeatureRow] = [:]
        for row in featureRows {
            guard let id = FloeBuildingCADGeometry.uuid(row["id"]) else { continue }
            let dependencies = row["dependencies"] as? [String: Any] ?? [:]
            let referenced = FloeBuildingCADGeometry.uuidStrings(row["referencedSketches"])
            let bodyIDs = Set(FloeBuildingCADGeometry.uuidStrings(dependencies["body_ids"]))
            let outputs = Set(FloeBuildingCADGeometry.uuidStrings(row["output_body_ids"]))
            let kind = FloeBuildingCADGeometry.string(row["kind"]) ?? "unknown"
            let suppressed = row["suppressed"] as? Bool ?? false
            features[id] = FloeBuildingCADFeatureRow(
                id: id, kind: kind, suppressed: suppressed,
                referencedSketches: referenced,
                bodyIDs: bodyIDs, outputBodyIDs: outputs)
        }

        let sketchesOutcome = document.nativeQueryJSON(
            ["scope": "sketches", "sketchLimit": 512, "entityLimit": 32])
        guard sketchesOutcome.isOK,
              let sketchesPayload = FloeBuildingCADGeometry.object(sketchesOutcome),
              let sketchRows = sketchesPayload["rows"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState(
                sketchesOutcome.message ?? "The native sketch list could not be read.")
        }
        var sketches: [UUID: FloeBuildingCADSketchRow] = [:]
        for row in sketchRows {
            guard let id = FloeBuildingCADGeometry.uuid(row["id"]) else { continue }
            let entityRows = row["entityRows"] as? [[String: Any]] ?? []
            let entities: [FloeBuildingCADEntityRow] = entityRows.compactMap { entity in
                guard let entityID = FloeBuildingCADGeometry.uuid(entity["id"]),
                      let kind = FloeBuildingCADGeometry.string(entity["kind"]) else { return nil }
                return FloeBuildingCADEntityRow(
                    id: entityID, kind: kind,
                    minimum: FloeBuildingCADGeometry.doubleArray(entity["min"]),
                    maximum: FloeBuildingCADGeometry.doubleArray(entity["max"]))
            }
            sketches[id] = FloeBuildingCADSketchRow(id: id, entities: entities)
        }

        let assembly = CADAssemblyService(document: document)
        let instancesReply = assembly.handle(action: "instances", args: [:])
        guard instancesReply["ok"] as? Bool == true,
              let instanceRows = instancesReply["instances"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState(
                instancesReply["message"] as? String ?? "The native assembly instances could not be read.")
        }
        var instances: [UUID: FloeBuildingCADInstanceRow] = [:]
        for row in instanceRows {
            guard let id = FloeBuildingCADGeometry.uuid(row["id"]),
                  let bodyID = FloeBuildingCADGeometry.uuid(row["bodyID"]) else { continue }
            let transform = row["transform"] as? [String: Any] ?? [:]
            let parentRaw = row["parentID"]
            let parentID: UUID? = parentRaw is NSNull ? nil : FloeBuildingCADGeometry.uuid(parentRaw)
            instances[id] = FloeBuildingCADInstanceRow(
                id: id, name: row["name"] as? String ?? "",
                bodyID: bodyID,
                effectiveBodyID: FloeBuildingCADGeometry.uuid(row["effectiveBodyID"]),
                hidden: row["hidden"] as? Bool ?? false,
                isSubassembly: row["isSubassembly"] as? Bool ?? false,
                parentID: parentID,
                position: FloeBuildingCADGeometry.doubleArray(transform["position"]) ?? [],
                rotation: FloeBuildingCADGeometry.doubleArray(transform["rotation"]) ?? [],
                scale: FloeBuildingCADGeometry.doubleArray(transform["scale"]) ?? [])
        }
        return FloeBuildingCADNativeState(features: features, sketches: sketches, instances: instances)
    }

    func measureNativeBody(_ bodyID: UUID) throws -> FloeBuildingCADMeasurement {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID.uuidString])
        guard outcome.isOK,
              let object = FloeBuildingCADGeometry.object(outcome),
              let rows = object["bounds"] as? [[Any]],
              rows.count == 2 else {
            throw FloeBuildingCADError.invalidNativeState(
                outcome.message ?? "The body \(bodyID.uuidString) could not be measured.")
        }
        let minimum = rows[0].compactMap { FloeBuildingCADGeometry.number($0) }
        let maximum = rows[1].compactMap { FloeBuildingCADGeometry.number($0) }
        guard minimum.count == 3, maximum.count == 3,
              let volume = FloeBuildingCADGeometry.number(object["volumeMM3"]) else {
            throw FloeBuildingCADError.invalidNativeState(
                "The body \(bodyID.uuidString) returned incomplete bounds or volume.")
        }
        return FloeBuildingCADMeasurement(
            boundsMinimum: minimum, boundsMaximum: maximum,
            volumeMM3: volume,
            analyticBRep: object["analyticBRep"] as? Bool ?? false)
    }

    /// Add one panel body and one assembly instance through the public CAD
    /// command vocabulary. The sketch/extrude/transform feature ids and the
    /// final body id are all retained for later in-place updates.
    func createCabinetPanel(_ panel: CabinetPanel) throws -> FloeBuildingCADPanelBinding {
        let rectMin = [panel.originMM.x, panel.originMM.y]
        let rectMax = [panel.originMM.x + panel.sizeMM.x,
                       panel.originMM.y + panel.sizeMM.y]
        let sketch = try executeNative("sketch.create",
            ["name": "Cabinet panel \(panel.id)"])
        guard let sketchID = FloeBuildingCADGeometry.uuid(sketch["sketchID"]) else {
            throw FloeBuildingCADError.invalidNativeState("sketch.create returned no sketchID.")
        }
        let rectangle: [String: Any] = [
            "kind": "rect", "min": rectMin, "max": rectMax,
        ]
        let entities = try executeNative("sketch.addEntities", [
            "sketchID": sketchID.uuidString,
            "entities": [rectangle],
        ])
        guard let entityIDs = entities["entityIDs"] as? [String],
              entityIDs.count == 1,
              let entityID = UUID(uuidString: entityIDs[0]) else {
            throw FloeBuildingCADError.invalidNativeState(
                "sketch.addEntities returned no single rectangle entity.")
        }
        let center = [(rectMin[0] + rectMax[0]) / 2, (rectMin[1] + rectMax[1]) / 2]
        let extrude = try executeNative("feature.extrude", [
            "sketchID": sketchID.uuidString,
            "seedPoint": center,
            "distance": panel.sizeMM.z,
        ])
        guard let extrudeFeatureID = FloeBuildingCADGeometry.uuid(extrude["featureID"]),
              let produced = extrude["producedBodyIDs"] as? [String],
              let bodyID = produced.first.flatMap(UUID.init(uuidString:)) else {
            throw FloeBuildingCADError.invalidNativeState(
                "feature.extrude returned no produced body.")
        }
        var moverFeatureIDs: [UUID] = []
        if abs(panel.originMM.z) > 1e-9 {
            let moved = try executeNative("feature.transform", [
                "bodyID": bodyID.uuidString,
                "translation": [0, panel.originMM.z, 0],
            ])
            guard let moverID = FloeBuildingCADGeometry.uuid(moved["featureID"]) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "feature.transform returned no feature id.")
            }
            moverFeatureIDs.append(moverID)
        }
        let assembly = CADAssemblyService(document: document)
        let placed = assembly.handle(action: "addInstance", args: [
            "bodyID": bodyID.uuidString,
            "name": panel.id,
        ])
        guard placed["ok"] as? Bool == true,
              let instanceID = FloeBuildingCADGeometry.uuid(placed["id"]) else {
            throw FloeBuildingCADError.invalidNativeState(
                placed["message"] as? String ?? "The cabinet panel instance could not be created.")
        }
        let measured = try measureNativeBody(bodyID)
        guard measured.analyticBRep else {
            throw FloeBuildingCADError.invalidNativeState(
                "The cabinet panel \(panel.id) is not an analytic solid.")
        }
        let expected = FloeBuildingCADCabinetRules.worldBounds(panel)
        guard FloeBuildingCADGeometry.approxEqual(
                measured.boundsMinimum, expected.minimum, tolerance: FloeBuildingCADGeometry.linearToleranceMM),
              FloeBuildingCADGeometry.approxEqual(
                measured.boundsMaximum, expected.maximum, tolerance: FloeBuildingCADGeometry.linearToleranceMM),
              abs(measured.volumeMM3 - panel.volumeM3 * 1_000_000_000) <= FloeBuildingCADGeometry.volumeToleranceMM3 else {
            throw FloeBuildingCADError.invalidNativeState(
                "The cabinet panel \(panel.id) did not match its generated bounds/volume.")
        }
        return FloeBuildingCADPanelBinding(
            panelID: panel.id, role: panel.role.rawValue,
            bodyID: bodyID, sketchID: sketchID, entityID: entityID,
            extrudeFeatureID: extrudeFeatureID,
            moverFeatureIDs: moverFeatureIDs, instanceID: instanceID,
            sketchRectMin: rectMin, sketchRectMax: rectMax,
            extrusionMM: panel.sizeMM.z,
            originMM: panel.originMM.values, sizeMM: panel.sizeMM.values,
            worldBoundsMin: measured.boundsMinimum,
            worldBoundsMax: measured.boundsMaximum,
            volumeMM3: measured.volumeMM3,
            materialID: panel.material.id,
            materialVersion: panel.material.version,
            materialThicknessMM: panel.material.thicknessMM)
    }

    /// Update one panel's existing sketch/extrude/owned transform features.
    /// The sketch edit carries its live fences; the body id is never re-minted.
    func updateCabinetPanel(_ binding: FloeBuildingCADPanelBinding,
                            to panel: CabinetPanel,
                            state: FloeBuildingCADNativeState) throws -> FloeBuildingCADPanelBinding {
        guard let sketch = state.sketches[binding.sketchID],
              sketch.entities.count == 1,
              let entity = sketch.entities.first,
              entity.kind == "rect",
              let liveMin = entity.minimum,
              let liveMax = entity.maximum else {
            throw FloeBuildingCADError.externalModification(
                "Panel \(binding.panelID): the owned rectangle entity is missing or was changed.")
        }
        let newMin = [panel.originMM.x, panel.originMM.y]
        let newMax = [panel.originMM.x + panel.sizeMM.x,
                      panel.originMM.y + panel.sizeMM.y]
        let parameters = CADParameterService(document: document)
        var moverFeatureIDs = binding.moverFeatureIDs
        if !FloeBuildingCADGeometry.approxEqual(newMin, binding.sketchRectMin, tolerance: 1e-9)
            || !FloeBuildingCADGeometry.approxEqual(newMax, binding.sketchRectMax, tolerance: 1e-9) {
            let reply = parameters.handle(action: "updateSketchEntity", args: [
                "sketch_id": binding.sketchID.uuidString,
                "entity_id": binding.entityID.uuidString,
                "min": newMin,
                "max": newMax,
                "expected_min": liveMin,
                "expected_max": liveMax,
            ])
            guard reply["ok"] as? Bool == true else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The panel \(binding.panelID) sketch update was refused: \(reply["message"] as? String ?? "unknown")")
            }
        }
        if abs(panel.sizeMM.z - binding.extrusionMM) > 1e-9 {
            let changes: [String: Any] = ["distance": panel.sizeMM.z]
            let reply = parameters.handle(action: "update", args: [
                "feature_id": binding.extrudeFeatureID.uuidString,
                "changes": changes,
            ])
            guard reply["ok"] as? Bool == true else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The panel \(binding.panelID) extrusion update was refused: \(reply["message"] as? String ?? "unknown")")
            }
        }
        let oldZ = binding.originMM.count == 3 ? binding.originMM[2] : 0
        let deltaZ = panel.originMM.z - oldZ
        if abs(deltaZ) > 1e-9 {
            let moved = try executeNative("feature.transform", [
                "bodyID": binding.bodyID.uuidString,
                "translation": [0, deltaZ, 0],
            ])
            guard let moverID = FloeBuildingCADGeometry.uuid(moved["featureID"]) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The panel \(binding.panelID) translation returned no feature id.")
            }
            moverFeatureIDs.append(moverID)
        }
        let measured = try measureNativeBody(binding.bodyID)
        let expected = FloeBuildingCADCabinetRules.worldBounds(panel)
        guard measured.analyticBRep,
              FloeBuildingCADGeometry.approxEqual(
                measured.boundsMinimum, expected.minimum, tolerance: FloeBuildingCADGeometry.linearToleranceMM),
              FloeBuildingCADGeometry.approxEqual(
                measured.boundsMaximum, expected.maximum, tolerance: FloeBuildingCADGeometry.linearToleranceMM),
              abs(measured.volumeMM3 - panel.volumeM3 * 1_000_000_000) <= FloeBuildingCADGeometry.volumeToleranceMM3 else {
            throw FloeBuildingCADError.invalidNativeState(
                "The panel \(binding.panelID) did not converge to its requested bounds/volume.")
        }
        return FloeBuildingCADPanelBinding(
            panelID: binding.panelID, role: panel.role.rawValue,
            bodyID: binding.bodyID, sketchID: binding.sketchID,
            entityID: binding.entityID,
            extrudeFeatureID: binding.extrudeFeatureID,
            moverFeatureIDs: moverFeatureIDs, instanceID: binding.instanceID,
            sketchRectMin: newMin, sketchRectMax: newMax,
            extrusionMM: panel.sizeMM.z,
            originMM: panel.originMM.values, sizeMM: panel.sizeMM.values,
            worldBoundsMin: measured.boundsMinimum,
            worldBoundsMax: measured.boundsMaximum,
            volumeMM3: measured.volumeMM3,
            materialID: panel.material.id,
            materialVersion: panel.material.version,
            materialThicknessMM: panel.material.thicknessMM)
    }
}

nonisolated enum FloeBuildingCADCabinetRules {
    static func rectMin(_ panel: CabinetPanel) -> [Double] {
        [panel.originMM.x, panel.originMM.y]
    }

    static func rectMax(_ panel: CabinetPanel) -> [Double] {
        [panel.originMM.x + panel.sizeMM.x,
         panel.originMM.y + panel.sizeMM.y]
    }

    static func worldBounds(_ panel: CabinetPanel) -> (minimum: [Double], maximum: [Double]) {
        (minimum: [panel.originMM.x, panel.originMM.z, -panel.originMM.y - panel.sizeMM.y],
         maximum: [panel.originMM.x + panel.sizeMM.x,
                   panel.originMM.z + panel.sizeMM.z,
                   -panel.originMM.y])
    }

    static func assemblyPanels(_ assembly: CabinetAssembly) -> [String: CabinetPanel] {
        Dictionary(uniqueKeysWithValues: assembly.panels.map { ($0.id, $0) })
    }
}
#endif
