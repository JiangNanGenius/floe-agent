// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import simd

/// UI and cad.document scene payloads use this same transaction path. World
/// placements remain in their original payloads; local leaf poses are derived.
@MainActor
public final class CADSceneObjectService {
    public static let reads: Set<String> = ["objects", "object.resources"]
    public static let mutations: Set<String> = ["object.createGroup", "object.reparent", "object.transform", "object.rename", "object.remove"]
    private let document: FloeCADDocument
    /// Per-generation read memo only, invalidated by the actual document
    /// change count. Payloads remain in their original stores. In particular,
    /// listing 4096 objects must not decode assembly/settings JSON per row.
    private struct ReadContext {
        var changeCount: Int
        var bodies: [Body]
        var bodyByID: [UUID: Body]
        var settings: CADSceneSettings
        var appearance: CADViewAppearance
        var assembly: CADAssembly
        var occurrences: [CADAssemblyOccurrence]
        var occurrenceByID: [UUID: CADAssemblyOccurrence]
    }
    private var readMemo: ReadContext?
    private func context() throws -> ReadContext {
        if let readMemo, readMemo.changeCount == document.session.changeCount { return readMemo }
        let bodies = document.session.document.bodies, settings = document.cameraSceneSettings()
        let assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        let occurrences = assembly.occurrences(includeHidden: true)
        let value = ReadContext(changeCount: document.session.changeCount, bodies: bodies,
            bodyByID: Dictionary(uniqueKeysWithValues: bodies.map { ($0.id.raw, $0) }), settings: settings,
            appearance: CADViewAppearance.current(for: settings), assembly: assembly,
            occurrences: occurrences, occurrenceByID: Dictionary(uniqueKeysWithValues: occurrences.map { ($0.instance.id, $0) }))
        readMemo = value
        return value
    }
    public init(document: FloeCADDocument) { self.document = document }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        guard !document.isClosed else { return failure("document_closed", FloeCADStrings.text("cad.scene.closed", "The document is closed.")) }
        if let refused = CADServiceOperations.readOnlyRefusal(document: document, kind: "scene", action: action) { return refused }
        do {
            if let raw = args["expected_change_count"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue == Double(document.session.changeCount) else {
                    return failure("concurrent_edit", FloeCADStrings.text("cad.scene.changed", "Re-read the object hierarchy before editing it."))
                }
            }
            let graph = try CADSceneObjectCodec.hierarchy(document.session.document.sceneSettingsData)
            if Self.reads.contains(action) {
                var resourceID: UUID?
                if action == "object.resources", let raw = args["id"] {
                    guard let text = raw as? String, let id = UUID(uuidString: text) else { throw CADSceneObjectError.missingObject }
                    resourceID = id
                }
                return ["ok": true, "mutated": false, "objects": try rows(graph),
                        "resources": action == "object.resources" ? try resources(for: resourceID) : [], "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "parent_kinds": ["group"], "world_pose_authority": "existing_document_payloads"]
            }
            guard Self.mutations.contains(action), !document.isReadOnly, document.session.writeBlock == nil else {
                return failure("read_only", FloeCADStrings.text("cad.scene.readOnly", "This document cannot be changed."))
            }
            if Task.isCancelled { throw CADSceneObjectError.cancelled }
            return try mutate(action, args, graph: graph)
        } catch let error as CADSceneObjectError { return failure(error.rawValue, error.localizedDescription) }
        catch { return failure("invalid_scene_hierarchy", error.localizedDescription) }
    }

    private func failure(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "mutated": false, "error": code, "message": message]
    }

    private func links(_ graph: CADSceneObjectHierarchy) throws -> [CADSceneObjectLink] {
        var result = graph.nodes, byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.kind) })
        func add(_ id: UUID, _ kind: CADSceneObjectKind) throws {
            if let existing = byID[id] {
                guard existing == kind else { throw CADSceneObjectError.invalidHierarchy }
            } else { result.append(.init(id: id, kind: kind)); byID[id] = kind }
        }
        let source = try context()
        for body in source.bodies { try add(body.id.raw, .body) }
        for occurrence in source.occurrences { try add(occurrence.instance.id, .assembly) }
        for light in source.appearance.sceneLights ?? [] { try add(light.id, .light) }
        for camera in source.settings.savedCameras ?? [] { try add(camera.id, .camera) }
        guard result.count <= CADSceneObjectHierarchy.maximumCount else { throw CADSceneObjectError.invalidHierarchy }
        return result
    }

    private func parent(_ link: CADSceneObjectLink) throws -> UUID? {
        if link.kind == .assembly,
           let native = try context().occurrenceByID[link.id]?.parentInstanceID {
            guard link.parentID == nil else { throw CADSceneObjectError.assemblyParent }
            return native
        }
        return link.parentID
    }

    private func world(_ link: CADSceneObjectLink, _ graph: CADSceneObjectHierarchy) throws -> CADTransform {
        switch link.kind {
        case .group: return try graph.groupWorld(link.id)
        case .body:
            guard let body = try context().bodyByID[link.id] else { throw CADSceneObjectError.missingObject }
            return CADSceneObjectCodec.pose(body.transform)
        case .assembly:
            guard let value = try context().occurrenceByID[link.id]?.worldTransform else { throw CADSceneObjectError.missingObject }
            return value
        case .light:
            guard let light = try context().appearance.sceneLights?.first(where: { $0.id == link.id }) else { throw CADSceneObjectError.missingObject }
            try light.validate()
            let direction = simd_normalize(SIMD3(light.direction[0], light.direction[1], light.direction[2]))
            return CADTransform(position: SIMD3(light.positionMM[0], light.positionMM[1], light.positionMM[2]),
                rotation: simd_quatd(from: SIMD3(0, 0, -1), to: direction).vector)
        case .camera:
            guard let camera = try context().settings.savedCameras?.first(where: { $0.id == link.id }), camera.sanitized != nil else { throw CADSceneObjectError.missingObject }
            return cameraWorld(camera)
        }
    }

    private func cameraWorld(_ camera: CADSavedCamera) -> CADTransform {
        let a = camera.azimuthRadians, e = camera.elevationRadians
        let z = SIMD3(cos(e) * sin(a), sin(e), cos(e) * cos(a))
        let x = SIMD3(cos(a), 0, -sin(a)), y = simd_cross(z, x)
        return CADTransform(position: camera.targetMM + z * camera.distanceMM,
                            rotation: simd_quatd(simd_double3x3(columns: (x, y, z))).vector)
    }

    private func name(_ link: CADSceneObjectLink) -> String {
        let source = try? context()
        switch link.kind {
        case .group: return link.groupName ?? FloeCADStrings.text("cad.scene.group", "Group")
        case .body: return source?.bodyByID[link.id]?.name ?? FloeCADStrings.text("cad.scene.missingBody", "Missing body")
        case .assembly: return source?.occurrenceByID[link.id]?.instance.name ?? FloeCADStrings.text("cad.scene.missingPart", "Missing part")
        case .light: return source?.appearance.sceneLights?.first { $0.id == link.id }?.name ?? FloeCADStrings.text("cad.scene.missingLight", "Missing light")
        case .camera: return source?.settings.savedCameras?.first { $0.id == link.id }?.name ?? FloeCADStrings.text("cad.scene.missingCamera", "Missing camera")
        }
    }

    func rows(_ graph: CADSceneObjectHierarchy) throws -> [[String: Any]] {
        let all = try links(graph), byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let groupPoses = try graph.groupWorlds(), source = try context()
        func resolved(_ link: CADSceneObjectLink) throws -> CADTransform {
            if link.kind == .group {
                guard let pose = groupPoses[link.id] else { throw CADSceneObjectError.invalidHierarchy }
                return pose
            }
            return try world(link, graph)
        }
        return try all.map { link in
            let parentID = try parent(link)
            var row: [String: Any] = ["id": link.id.uuidString, "kind": link.kind.rawValue,
                "name": name(link), "parent_id": parentID?.uuidString ?? "",
                "explicit": graph.nodes.contains { $0.id == link.id }]
            do {
                let pose = try resolved(link)
                let parentPose: CADTransform
                if let parentID, let owner = byID[parentID] { parentPose = try resolved(owner) }
                else { parentPose = .identity }
                row["world"] = CADSceneObjectCodec.transformJSON(pose)
                row["local"] = CADSceneObjectCodec.transformJSON(try CADSceneObjectCodec.inverse(parentPose).concatenating(pose))
                row["available"] = true
                if link.kind == .light { row["orientation_semantics"] = "direction_only" }
                if link.kind == .camera { row["orientation_semantics"] = "orbit_without_roll" }
                if link.kind == .light || link.kind == .camera { row["scale_editable"] = false }
                if link.kind == .assembly,
                   let occurrence = source.occurrenceByID[link.id],
                   let id = occurrence.effectiveBodyID,
                   let body = source.bodyByID[id] {
                    row["source_body_id"] = id.uuidString
                    row["geometry_world"] = CADSceneObjectCodec.transformJSON(pose.concatenating(CADSceneObjectCodec.pose(body.transform)))
                    row["source_reference_id"] = occurrence.sourceReferenceID?.uuidString ?? ""
                }
            } catch {
                row["available"] = false; row["error"] = "scene_object_missing"
            }
            return row
        }
    }

    private func resources(for objectID: UUID?) throws -> [[String: Any]] {
        let sourceAssembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        let bodyFilter: UUID?
        if let objectID {
            if document.session.document.bodies.contains(where: { $0.id.raw == objectID }) { bodyFilter = objectID }
            else if let id = sourceAssembly.occurrence(objectID)?.effectiveBodyID { bodyFilter = id }
            else { throw CADSceneObjectError.missingObject }
        } else { bodyFilter = nil }
        var result: [[String: Any]] = []
        var bytesRead = 0
        func budget(_ bytes: Int) throws {
            guard bytes <= 64 * 1024 * 1024 - bytesRead, result.count < 8192 else { throw CADSceneObjectError.resourceLimit }
            bytesRead += bytes
        }
        for body in document.session.document.bodies where bodyFilter == nil || body.id.raw == bodyFilter {
            let materials = [body.material].compactMap { $0 } + body.materialFaceBindings.map(\.material)
            for material in materials {
                if let id = material.materialID { try budget(0); result.append(["kind": "material", "body_id": body.id.raw.uuidString, "id": id]) }
                for slot in MaterialTextureSlot.allCases {
                    if let bytes = material.textureData(for: slot) {
                        try budget(bytes.count)
                        result.append(["kind": "texture", "body_id": body.id.raw.uuidString,
                            "slot": slot.rawValue, "sha256": CADMaterialTexture.digest(bytes), "byte_count": bytes.count])
                    }
                }
            }
        }
        if objectID == nil, let map = document.viewAppearance.environmentMap {
            try budget(map.bytes?.count ?? 0)
            result.append(["kind": "environment", "sha256": map.sha256, "available": (try? map.checkedBytes()) != nil])
        }
        if let assembly = try? CADAssembly.decode(from: document.session.document.assemblyData) {
            for occurrence in assembly.occurrences(includeHidden: true) {
                if let objectID, occurrence.instance.id != objectID && occurrence.effectiveBodyID != objectID { continue }
                if let id = occurrence.sourceReferenceID {
                    try budget(0)
                    let reference = assembly.partReferences.first { $0.id == id }
                    result.append(["kind": "part_reference", "instance_id": occurrence.instance.id.uuidString, "id": id.uuidString,
                        "source_sha256": reference?.sourceContentHash ?? "", "staged_sha256": reference?.stagedGeometryHash ?? ""])
                }
            }
        }
        guard result.count <= 8192 else { throw CADSceneObjectError.resourceLimit }
        return result
    }

    private func boolean(_ raw: Any?, default fallback: Bool) throws -> Bool {
        guard let raw else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw CADSceneObjectError.invalidTransform
        }
        return value.boolValue
    }

    private func parsePose(_ raw: Any?) throws -> CADTransform {
        guard let row = raw as? [String: Any], Set(row.keys).isSubset(of: ["position", "rotation", "scale"]),
              let pose = try? JSONDecoder().decode(CADTransform.self, from: JSONSerialization.data(withJSONObject: row)),
              pose.isPlaceable, (0..<3).allSatisfy({ abs(pose.position[$0]) <= 1e9 }),
              (1e-9...1e9).contains(pose.scale.x) else { throw CADSceneObjectError.invalidTransform }
        var result = pose; result.rotation = simd_normalize(simd_quatd(vector: pose.rotation)).vector
        return result
    }

    private func mutate(_ action: String, _ args: [String: Any], graph original: CADSceneObjectHierarchy) throws -> [String: Any] {
        var graph = original, settings = document.cameraSceneSettings()
        var assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        let originalAssembly = assembly
        var delta: CADTransform?, moved = Set<UUID>(), extra: [DocumentCommand] = []
        let all = try links(original)
        let requestedID = (args["id"] as? String).flatMap(UUID.init(uuidString:))
        var outputID = requestedID
        if action == "object.createGroup" {
            guard let raw = args["name"] as? String, let name = CADSavedCamera.normalizedName(raw) else { throw CADSceneObjectError.invalidHierarchy }
            let id = UUID(); outputID = id
            graph.nodes.append(.init(id: id, kind: .group, groupName: name, groupTransform: .identity))
        } else {
            guard let id = requestedID, let current = all.first(where: { $0.id == id }) else { throw CADSceneObjectError.missingObject }
            if !graph.nodes.contains(where: { $0.id == id }) { graph.nodes.append(current) }
            guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { throw CADSceneObjectError.missingObject }
            switch action {
            case "object.reparent":
                var parentID: UUID?
                if let raw = args["parent_id"], !(raw is NSNull), (raw as? String) != "" {
                    guard let text = raw as? String, let parsed = UUID(uuidString: text),
                          graph.nodes.contains(where: { $0.id == parsed && $0.kind == .group }) else { throw CADSceneObjectError.invalidHierarchy }
                    parentID = parsed
                }
                if current.kind == .assembly, assembly.parentInstanceID(of: id) != nil { throw CADSceneObjectError.assemblyParent }
                let before = try world(current, original)
                let oldParent = try original.groupWorld(current.parentID)
                graph.nodes[index].parentID = parentID
                try graph.validate() // cycles rejected before any pose or command
                let nextParent = try graph.groupWorld(parentID)
                let keepWorld = try boolean(args["keep_world"], default: true)
                if current.kind == .group {
                    if keepWorld { graph.nodes[index].groupTransform = try CADSceneObjectCodec.inverse(nextParent).concatenating(before) }
                    else { delta = try nextParent.concatenating(CADSceneObjectCodec.inverse(oldParent)); moved = original.descendants(of: id) }
                } else if !keepWorld {
                    delta = try nextParent.concatenating(CADSceneObjectCodec.inverse(oldParent)); moved = [id]
                }
            case "object.transform":
                guard args["frame"] == nil || args["frame"] is String else { throw CADSceneObjectError.invalidTransform }
                let frame = args["frame"] as? String ?? "local"
                guard ["local", "world"].contains(frame) else { throw CADSceneObjectError.invalidTransform }
                let requested = try parsePose(args["transform"])
                let before = try world(current, original)
                let parentWorld: CADTransform
                if current.kind == .assembly, let parent = assembly.parentInstanceID(of: id) {
                    parentWorld = assembly.worldTransform(for: parent) ?? .identity
                } else { parentWorld = try original.groupWorld(current.parentID) }
                let desired = frame == "world" ? requested : parentWorld.concatenating(requested)
                delta = desired.concatenating(try CADSceneObjectCodec.inverse(before))
                if current.kind == .group {
                    graph.nodes[index].groupTransform = try CADSceneObjectCodec.inverse(parentWorld).concatenating(desired)
                    moved = original.descendants(of: id)
                } else { moved = [id] }
            case "object.remove":
                let children = graph.nodes.filter { $0.parentID == id }
                let promote = try boolean(args["promote_children"], default: false)
                guard children.isEmpty || promote else { throw CADSceneObjectError.referenced }
                for child in children {
                    guard let childIndex = graph.nodes.firstIndex(where: { $0.id == child.id }) else { continue }
                    if child.kind == .group {
                        graph.nodes[childIndex].groupTransform = try CADSceneObjectCodec.inverse(original.groupWorld(current.parentID)).concatenating(original.groupWorld(child.id))
                    }
                    graph.nodes[childIndex].parentID = current.parentID
                }
                graph.nodes.removeAll { $0.id == id } // detach only, never deletes payload/resources
            case "object.rename":
                guard let raw = args["name"] as? String, let name = CADSavedCamera.normalizedName(raw) else { throw CADSceneObjectError.invalidHierarchy }
                switch current.kind {
                case .group: graph.nodes[index].groupName = name
                case .body:
                    guard let body = document.session.document.bodies.first(where: { $0.id.raw == id }) else { throw CADSceneObjectError.missingObject }
                    extra.append(RenameItemCommand(item: .body(body.id), before: body.name, after: name))
                case .assembly: guard assembly.updateInstance(id, { $0.name = name }) else { throw CADSceneObjectError.missingObject }
                case .light:
                    guard let i = settings.presentation?.sceneLights?.firstIndex(where: { $0.id == id }) else { throw CADSceneObjectError.missingObject }
                    settings.presentation?.sceneLights?[i].name = name
                case .camera:
                    guard let i = settings.savedCameras?.firstIndex(where: { $0.id == id }) else { throw CADSceneObjectError.missingObject }
                    settings.savedCameras?[i].name = name
                }
            default: throw CADSceneObjectError.invalidHierarchy
            }
        }
        try graph.validate()
        var appends: [FeatureNode] = [], edits: [EditFeatureCommand] = []
        if let delta {
            // Native assembly descendants are implicit children of any moving
            // occurrence. Never apply both a parent delta and its child delta.
            let movingAssembly = Set(all.filter { moved.contains($0.id) && $0.kind == .assembly }.map(\.id))
            let definitions = Set(all.filter { moved.contains($0.id) && $0.kind == .body }.map(\.id))
            let occurrences = assembly.occurrences(includeHidden: true)
            guard !occurrences.contains(where: { $0.effectiveBodyID.map(definitions.contains) == true }) else { throw CADSceneObjectError.definitionScope }
            let leaves = all.filter { moved.contains($0.id) && $0.kind != .group }
            guard leaves.count <= 128 else { throw CADSceneObjectError.invalidHierarchy }
            for link in leaves {
                switch link.kind {
                case .body: try bodyPlacement(link.id, delta, appends: &appends, edits: &edits)
                case .assembly:
                    guard let occurrence = originalAssembly.occurrence(link.id) else { throw CADSceneObjectError.missingObject }
                    if occurrence.path.dropLast().contains(where: movingAssembly.contains) { continue }
                    let before = occurrence.worldTransform
                    let parentWorld = occurrence.parentInstanceID.flatMap { originalAssembly.worldTransform(for: $0) } ?? .identity
                    let local = try CADSceneObjectCodec.inverse(parentWorld).concatenating(delta.concatenating(before))
                    guard local.isPlaceable, assembly.updateInstance(link.id, { $0.transform = local }) else { throw CADSceneObjectError.invalidTransform }
                case .light:
                    guard abs(delta.scale.x - 1) <= 1e-9 else { throw CADSceneObjectError.invalidTransform }
                    guard let i = settings.presentation?.sceneLights?.firstIndex(where: { $0.id == link.id }),
                          var light = settings.presentation?.sceneLights?[i] else { throw CADSceneObjectError.missingObject }
                    let transform = delta.placement3D()
                    let p = transform.applying(to: SIMD3(light.positionMM[0], light.positionMM[1], light.positionMM[2]))
                    let d = transform.rotation.act(SIMD3(light.direction[0], light.direction[1], light.direction[2]))
                    light.positionMM = [p.x, p.y, p.z]; light.direction = [d.x, d.y, d.z]
                    light.radiusMM *= transform.scale; try light.validate()
                    settings.presentation?.sceneLights?[i] = light
                case .camera:
                    guard abs(delta.scale.x - 1) <= 1e-9 else { throw CADSceneObjectError.cameraRoll }
                    guard let i = settings.savedCameras?.firstIndex(where: { $0.id == link.id }),
                          var camera = settings.savedCameras?[i] else { throw CADSceneObjectError.missingObject }
                    let transform = delta.placement3D(), oldPose = cameraWorld(camera)
                    let rotated = transform.rotation * simd_quatd(vector: oldPose.rotation)
                    let z = rotated.act(SIMD3(0, 0, 1))
                    let elevation = asin(min(1, max(-1, z.y))), azimuth = atan2(z.x, z.z)
                    let canonicalX = SIMD3(cos(azimuth), 0, -sin(azimuth))
                    guard simd_length(rotated.act(SIMD3(1, 0, 0)) - canonicalX) <= 1e-7 else { throw CADSceneObjectError.cameraRoll }
                    camera.targetMM = transform.applying(to: camera.targetMM)
                    camera.distanceMM *= transform.scale; camera.azimuthRadians = azimuth; camera.elevationRadians = elevation
                    guard let valid = camera.sanitized, valid == camera else { throw CADSceneObjectError.cameraRoll }
                    settings.savedCameras?[i] = camera
                case .group: break
                }
            }
        }
        _ = try links(graph) // total implicit + explicit node bound before commit
        settings.sceneObjects = graph.nodes.isEmpty ? nil : graph
        let after = try JSONEncoder().encode(settings)
        if after != document.session.document.sceneSettingsData {
            extra.append(SetSceneSettingsDataCommand(before: document.session.document.sceneSettingsData, after: after))
        }
        if assembly != originalAssembly { extra.append(SetAssemblyDataCommand(before: document.session.document.assemblyData, after: try assembly.encoded())) }
        guard !Task.isCancelled else { throw CADSceneObjectError.cancelled }
        let session = document.session, checkpoint = session.captureEditCheckpoint(), before = session.changeCount
        let applied: Bool
        if appends.isEmpty && edits.isEmpty {
            session.perform(CompositeCommand(title: "Scene objects", commands: extra))
            applied = session.lastSceneObjectFailure == nil
        } else { applied = session.applySceneObjectEdit(appending: appends, editing: edits, extra: extra) }
        guard applied, session.lastEvalErrors.isEmpty, session.lastSceneObjectFailure == nil else {
            if session.changeCount != before { session.restoreEditCheckpoint(checkpoint) }
            throw session.lastSceneObjectFailure ?? CADSceneObjectError.failed
        }
        return ["ok": true, "mutated": session.changeCount != before,
                "id": outputID?.uuidString ?? "", "objects": try rows(graph),
                "revision": document.revision, "change_count": session.changeCount]
    }

    private func bodyPlacement(_ id: UUID, _ delta: CADTransform,
                               appends: inout [FeatureNode], edits: inout [EditFeatureCommand]) throws {
        let session = document.session, bodyID = BodyID(raw: id), featureID = CADSceneObjectCodec.placementID(id)
        guard let body = session.document.body(with: bodyID), delta.isPlaceable,
              session.document.features.rollbackIndex == nil else { throw CADSceneObjectError.placementDependency }
        let graph = session.document.features
        if let index = graph.index(of: featureID) {
            let node = graph.nodes[index]
            guard !node.suppressed, case let .transform(reference, oldDelta) = node.kind,
                  reference.bodyID == bodyID,
                  !graph.nodes.dropFirst(index + 1).contains(where: { !$0.suppressed && ($0.consumedBodyIDs.contains(bodyID) || $0.outputBodyIDs.contains(bodyID)) }) else {
                throw CADSceneObjectError.placementDependency
            }
            edits.append(EditFeatureCommand(featureID: featureID, before: node.kind,
                after: .transform(body: reference, delta: delta.placement3D().composed(onto: oldDelta))))
        } else {
            let producer: FeatureID
            if let existing = session.lastBodyWriters[bodyID] ?? graph.nodes.last(where: { $0.outputBodyIDs.contains(bodyID) })?.id { producer = existing }
            else {
                let source = try NativeBodySource(capturing: body)
                let base = FeatureNode(name: "Imported body", kind: .baseSolid(source: source), outputBodyIDs: [bodyID])
                appends.append(base); producer = base.id
            }
            appends.append(FeatureNode(id: featureID, name: "Scene placement",
                kind: .transform(body: BodyRef(producer: producer, bodyID: bodyID), delta: delta.placement3D()), outputBodyIDs: [BodyID()]))
        }
    }
}
