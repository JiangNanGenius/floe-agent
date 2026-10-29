//
//  CADMaterialService.swift
//  FloeCADKit
//
//  Document-scoped custom-material library and application service.
//
//  Everything here is ordinary document state: library edits and body/face
//  applications are single undoable commands on the shared `DocumentSession`,
//  so the AI surface, the visible editor and undo/redo all agree. Applied
//  appearances are complete snapshots (`BodyMaterialSpec`), therefore removing
//  or updating a library entry never mutates a body unless the caller asks to
//  re-apply. No scripts or custom shaders are representable.
//

import Foundation
import simd

@MainActor
public final class CADMaterialService {
    /// Upper bound for the explicit shared-library file transport.
    public static let maximumSharedLibraryBytes = 96 * 1024 * 1024

    public static let actions: [String] = [
        "list", "read", "create", "update", "remove", "apply", "applyFaces",
        "reassignFaces", "mapping", "textures", "unresolved", "libraryExport",
        "libraryImport", "libraryList", "undo", "redo",
    ]

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    // MARK: - Router

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let failure = revisionPinFailure(args) { return failure }
        switch action {
        case "list": return list(args)
        case "read": return read(args)
        case "create": return create(args)
        case "update": return update(args)
        case "remove": return remove(args)
        case "apply": return apply(args)
        case "applyFaces": return applyFaces(args)
        case "reassignFaces": return reassignFaces(args)
        case "mapping": return mapping(args)
        case "textures": return textures(args)
        case "unresolved": return unresolvedList(args)
        case "libraryExport": return libraryExport(args)
        case "libraryImport": return libraryImport(args)
        case "libraryList": return libraryList(args)
        case "undo": return undo(args)
        case "redo": return redo(args)
        default:
            return Self.fail("unknown_action",
                             "Unknown material action '\(action)'. Use "
                                + Self.actions.joined(separator: ", ") + ".")
        }
    }

    /// Optional revision pin. The tool/bridge also checks it before touching
    /// anything; direct service callers get the same refusal instead of an
    /// ignored argument.
    private func revisionPinFailure(_ args: [String: Any]) -> [String: Any]? {
        guard let raw = args["revision"] ?? args["expected_revision"] else { return nil }
        let value: Int64
        if let raw = raw as? Int64 { value = raw }
        else if let raw = raw as? Int { value = Int64(raw) }
        else if let raw = raw as? NSNumber { value = raw.int64Value }
        else if let raw = raw as? String, let parsed = Int64(raw) { value = parsed }
        else { return Self.fail("bad_revision", "revision must be an integer.") }
        guard value == Int64(document.revision) else {
            return Self.fail(
                "revision_mismatch",
                "The document is at revision \(document.revision), not the requested "
                    + "\(value). Re-read it before this material action.")
        }
        return nil
    }

    // MARK: - Library reads

    private var library: CADMaterialLibrary {
        CADMaterialLibraryCodec.decode(document.session.document.materialLibraryData)
    }

    private func list(_ args: [String: Any]) -> [String: Any] {
        let library = self.library
        var applied: [String: Set<UUID>] = [:]
        for body in document.session.document.bodies {
            if let id = body.material?.materialID {
                applied[id, default: []].insert(body.id.raw)
            }
            for binding in body.materialFaceBindings {
                if let id = binding.material.materialID {
                    applied[id, default: []].insert(body.id.raw)
                }
            }
        }
        let rows = library.entries.map { entry -> [String: Any] in
            var row = entry.summaryJSON
            row["applied_body_ids"] = applied[entry.id.raw.uuidString].map { $0.map(\.uuidString).sorted() } ?? []
            return row
        }
        return Self.ok([
            "action": "list",
            "library_schema_version": library.schemaVersion,
            "count": rows.count,
            "materials": rows,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func read(_ args: [String: Any]) -> [String: Any] {
        guard let entry = lookupMaterial(args) else {
            return Self.fail("unknown_material",
                             "material_id (UUID) or material (name) must name a library entry.")
        }
        var row = entry.summaryJSON
        let bodyRefs = appliedBodyReferences(for: entry.id)
        row["bodies"] = bodyRefs
        return Self.ok(["action": "read", "material": row,
                        "revision": document.revision,
                        "change_count": document.session.changeCount])
    }

    private func unresolvedList(_ args: [String: Any]) -> [String: Any] {
        var rows: [[String: Any]] = []
        for body in document.session.document.bodies where !body.materialFaceBindings.isEmpty {
            for resolution in CADFaceMaterialResolver.resolve(body.materialFaceBindings, in: body) {
                guard resolution.resolvedIndex == nil else { continue }
                var row: [String: Any] = [
                    "body_id": body.id.raw.uuidString,
                    "body_name": body.name,
                    "material_name": resolution.binding.material.materialName ?? "Material",
                    "material_id": resolution.binding.material.materialID ?? "",
                    "captured_index": resolution.binding.key.capturedIndex ?? 0,
                    "face_signature": [
                        "kind": resolution.binding.key.signature.kind.materialKindName,
                        "centroid": Self.vector(resolution.binding.key.signature.centroid),
                        "normal": Self.vector(resolution.binding.key.signature.normal),
                        "areaMM2": resolution.binding.key.signature.area,
                    ],
                ]
                switch resolution.match {
                case .unresolved(let reason):
                    row["reason"] = reason
                case .ambiguous(let indices):
                    row["reason"] = "The stored signature matches more than one face."
                    row["candidate_indices"] = indices
                case .resolved:
                    continue
                }
                if let brep = body.brep {
                    row["current_faces"] = Array(OCCTKernel.faceInfo(brep).prefix(32)).map(\.stableFaceJSON)
                }
                rows.append(row)
            }
        }
        return Self.ok(["action": "unresolved", "count": rows.count, "bindings": rows,
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "note": rows.isEmpty ? "All face bindings resolve."
                            : "Reassign by current 1-based face index, then re-query faces before further edits."])
    }

    // MARK: - Library mutations

    private func create(_ args: [String: Any]) -> [String: Any] {
        guard let name = Self.string(args["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return Self.fail("missing_name", "create needs a material name.")
        }
        let now = Date()
        var definition = CADMaterialDefinition(name: name, createdAt: now, updatedAt: now)
        if let failure = applyFields(args, to: &definition) { return failure }
        definition = definition.sanitized
        var library = self.library
        guard library.entries.count < CADMaterialLimits.maximumLibraryEntries else {
            return Self.fail("library_full",
                             "The material library already holds \(CADMaterialLimits.maximumLibraryEntries) entries.")
        }
        library.upsert(definition)
        if let failure = writeLibrary(library) { return failure }
        return Self.ok(["action": "create", "mutated": true,
                        "material": definition.summaryJSON,
                        "id": definition.id.raw.uuidString,
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    private func update(_ args: [String: Any]) -> [String: Any] {
        guard let existing = lookupMaterial(args) else {
            return Self.fail("unknown_material",
                             "update needs material_id (UUID) or material (name).")
        }
        var definition = existing
        if let failure = applyFields(args, to: &definition) { return failure }
        definition.revision = max(existing.revision, 0) + 1
        definition.updatedAt = Date()
        definition = definition.sanitized
        var library = self.library
        library.upsert(definition)

        var reapplied: [String] = []
        var appearance: SetMaterialAppearanceCommand?
        if Self.bool(args["apply_to_applied"]) == true {
            let targets = document.session.document.bodies.filter { body in
                body.material?.materialID == existing.id.raw.uuidString
                    || body.materialFaceBindings.contains {
                        $0.material.materialID == existing.id.raw.uuidString
                    }
            }
            if !targets.isEmpty {
                let spec = definition.bodyMaterialSpec()
                var snapshots: [BodyID: SetMaterialAppearanceCommand.Snapshot] = [:]
                for body in targets {
                    var bindings = body.materialFaceBindings
                    for index in bindings.indices
                    where bindings[index].material.materialID == existing.id.raw.uuidString {
                        bindings[index].material = spec
                    }
                    snapshots[body.id] = .init(
                        material: body.material?.materialID == existing.id.raw.uuidString
                            ? spec : body.material,
                        faceBindings: bindings)
                    reapplied.append(body.id.raw.uuidString)
                }
                appearance = SetMaterialAppearanceCommand(
                    title: "Update Material", bodyIDs: Set(snapshots.keys),
                    after: snapshots, document: document.session.document)
            }
        }
        if let failure = commitLibrary(library, appearance: appearance,
                                       title: "Update Material") { return failure }
        return Self.ok(["action": "update", "mutated": true,
                        "material": definition.summaryJSON,
                        "reapplied_bodies": reapplied.sorted(),
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    private func remove(_ args: [String: Any]) -> [String: Any] {
        guard let existing = lookupMaterial(args) else {
            return Self.fail("unknown_material",
                             "remove needs material_id (UUID) or material (name).")
        }
        var library = self.library
        guard library.remove(existing.id) != nil else {
            return Self.fail("unknown_material", "No library entry \(existing.id.raw.uuidString).")
        }
        if let failure = writeLibrary(library) { return failure }
        let refs = appliedBodyReferences(for: existing.id)
        return Self.ok(["action": "remove", "mutated": true,
                        "removed": existing.id.raw.uuidString,
                        "applied_body_references": refs,
                        "applied_bodies_unchanged": true,
                        "note": "Applied body appearances are independent snapshots; they keep their look.",
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    private func writeLibrary(_ library: CADMaterialLibrary) -> [String: Any]? {
        commitLibrary(library, appearance: nil, title: "Material Library")
    }

    /// One undo step for a library change plus any applied-body refresh. A
    /// failed save then rolls BOTH back together, never leaving the library
    /// updated while its applied appearance is stale (or vice versa).
    private func commitLibrary(_ library: CADMaterialLibrary,
                               appearance: SetMaterialAppearanceCommand?,
                               title: String) -> [String: Any]? {
        guard let encoded = CADMaterialLibraryCodec.encode(library) else {
            return Self.fail("library_encode_failed",
                             "The material library could not be encoded within its size bound.")
        }
        let before = document.session.document.materialLibraryData
        var commands: [DocumentCommand] = []
        if before != encoded {
            commands.append(SetMaterialLibraryDataCommand(before: before, after: encoded))
        }
        if let appearance { commands.append(appearance) }
        guard !commands.isEmpty else { return nil }
        if commands.count == 1 {
            document.session.perform(commands[0])
        } else {
            document.session.perform(CompositeCommand(title: title, commands: commands))
        }
        return nil
    }

    // MARK: - Apply to bodies

    private func apply(_ args: [String: Any]) -> [String: Any] {
        guard let bodies = resolveBodies(args) else {
            return Self.fail("unknown_body", "apply needs bodyID or bodyIDs naming live bodies.")
        }
        let material: CADMaterialDefinition
        switch materialForApply(args) {
        case .failure(let error):
            return error.reply
        case .success(let value):
            guard let value else {
                return Self.fail("unknown_material",
                                 "apply needs material_id/material (a library entry) or inline color/maps.")
            }
            material = value
        }
        let spec = material.bodyMaterialSpec()
        var snapshots: [BodyID: SetMaterialAppearanceCommand.Snapshot] = [:]
        for body in bodies {
            snapshots[body.id] = .init(material: spec, faceBindings: [])
        }
        document.session.perform(SetMaterialAppearanceCommand(
            title: "Apply Material", bodyIDs: Set(snapshots.keys),
            after: snapshots, document: document.session.document))
        return Self.ok(mutationReply(action: "apply", material: material,
                                     bodyIDs: bodies.map(\.id.raw),
                                     extra: ["scope": "body",
                                             "faces_cleared": true]))
    }

    private func applyFaces(_ args: [String: Any]) -> [String: Any] {
        guard let body = resolveBodies(args)?.first else {
            return Self.fail("unknown_body", "applyFaces needs one bodyID.")
        }
        let material: CADMaterialDefinition
        switch materialForApply(args) {
        case .failure(let error):
            return error.reply
        case .success(let value):
            guard let value else {
                return Self.fail("unknown_material",
                                 "applyFaces needs material_id/material (a library entry) or inline color/maps.")
            }
            material = value
        }
        guard let rawFaces = args["faces"] as? [Int] ?? (args["faces"] as? [NSNumber])?.map(\.intValue),
              !rawFaces.isEmpty else {
            return Self.fail("missing_faces",
                             "applyFaces needs faces: 1-based kernel face indices from query kind=faces.")
        }
        let indices = Array(Set(rawFaces)).sorted()
        guard indices.allSatisfy({ $0 >= 1 }) else {
            return Self.fail("bad_face_index", "faces are 1-based kernel face indices.")
        }
        if let failure = validateFaceGeneration(args, body: body, indices: indices) {
            return failure
        }
        guard let brep = body.brep else {
            return Self.fail("mesh_body",
                             "This body has no analytic B-rep; use a whole-body material.")
        }
        let faces = Dictionary(uniqueKeysWithValues: OCCTKernel.faceInfo(brep).map { ($0.index, $0) })
        let missing = indices.filter { faces[$0] == nil }
        guard missing.isEmpty else {
            return Self.fail("unknown_face",
                             "Body '\(body.name)' has no face \(missing.map(String.init).joined(separator: ", ")). "
                                + "Re-query kind=faces for current indices.")
        }
        var bindings: [CADFaceMaterialBinding] = []
        var used: Set<Int> = []
        for existing in body.materialFaceBindings {
            if case .resolved(let index, _) = CADFaceMaterialResolver.match(
                existing.key, candidates: CADFaceMaterialResolver.candidates(for: body)),
               indices.contains(index) {
                continue
            }
            bindings.append(existing)
        }
        let spec = material.bodyMaterialSpec()
        for index in indices {
            guard let face = faces[index], let signature = face.signature else {
                return Self.fail("unstable_face",
                                 "Face \(index) of '\(body.name)' has no stable material signature; "
                                    + "use a whole-body material.")
            }
            let key = CADFaceKey(signature: signature, capturedIndex: index)
            if case let .ambiguous(candidates) = CADFaceMaterialResolver.match(
                key, candidates: CADFaceMaterialResolver.candidates(for: body)) {
                return Self.fail("ambiguous_face",
                                 "Face \(index) has ambiguous stable identity (candidates \(candidates)). "
                                    + "Re-query faces and assign the whole body or a uniquely shaped face.")
            }
            guard used.insert(index).inserted else { continue }
            bindings.append(CADFaceMaterialBinding(key: key, material: spec))
        }
        let snapshot = SetMaterialAppearanceCommand.Snapshot(
            material: body.material, faceBindings: bindings)
        document.session.perform(SetMaterialAppearanceCommand(
            title: "Face Material", bodyIDs: [body.id], after: [body.id: snapshot],
            document: document.session.document))
        return Self.ok(mutationReply(action: "applyFaces", material: material,
                                     bodyIDs: [body.id.raw],
                                     extra: ["scope": "faces", "faces": indices,
                                             "binding_count": bindings.count]))
    }

    /// Explicit replacement for stale/ambiguous bindings. `faces` names the
    /// CURRENT 1-based indices to rebuild; omit `material_id`/`material` to
    /// clear them. Nothing is guessed from the old captured index.
    private func reassignFaces(_ args: [String: Any]) -> [String: Any] {
        guard let body = resolveBodies(args)?.first else {
            return Self.fail("unknown_body", "reassignFaces needs one bodyID.")
        }
        guard let rawFaces = args["faces"] as? [Int] ?? (args["faces"] as? [NSNumber])?.map(\.intValue),
              !rawFaces.isEmpty else {
            return Self.fail("missing_faces",
                             "reassignFaces needs the current 1-based face indices from query kind=faces.")
        }
        let indices = Array(Set(rawFaces)).sorted()
        if let failure = validateFaceGeneration(args, body: body, indices: indices) {
            return failure
        }
        guard let brep = body.brep else {
            return Self.fail("mesh_body", "This body has no analytic B-rep.")
        }
        let faces = Dictionary(uniqueKeysWithValues: OCCTKernel.faceInfo(brep).map { ($0.index, $0) })
        let missing = indices.filter { faces[$0] == nil }
        guard missing.isEmpty else {
            return Self.fail("unknown_face",
                             "Body '\(body.name)' has no face \(missing.map(String.init).joined(separator: ", ")).")
        }
        let material: CADMaterialDefinition?
        switch materialForApply(args) {
        case .failure(let error):
            return error.reply
        case .success(let value):
            material = value
        }
        var bindings: [CADFaceMaterialBinding] = []
        for existing in body.materialFaceBindings {
            switch CADFaceMaterialResolver.match(
                existing.key, candidates: CADFaceMaterialResolver.candidates(for: body)) {
            case .resolved(let index, _) where indices.contains(index):
                continue
            case .resolved:
                bindings.append(existing)
            case .ambiguous, .unresolved:
                if Self.bool(args["drop_unresolved"]) ?? true {
                    continue
                }
                bindings.append(existing)
            }
        }
        if let material {
            let spec = material.bodyMaterialSpec()
            for index in indices {
                guard let face = faces[index], let signature = face.signature else {
                    return Self.fail("unstable_face", "Face \(index) has no stable material signature.")
                }
                bindings.append(CADFaceMaterialBinding(
                    key: CADFaceKey(signature: signature, capturedIndex: index), material: spec))
            }
        }
        document.session.perform(SetMaterialAppearanceCommand(
            title: "Reassign Face Material", bodyIDs: [body.id],
            after: [body.id: .init(material: body.material, faceBindings: bindings)],
            document: document.session.document))
        return Self.ok(mutationReply(action: "reassignFaces", material: material,
                                     bodyIDs: [body.id.raw],
                                     extra: ["scope": "faces", "faces": indices,
                                             "binding_count": bindings.count]))
    }

    // MARK: - Mapping / textures

    private func mapping(_ args: [String: Any]) -> [String: Any] {
        guard let raw = args["mapping"] as? [String: Any],
              let map = CADMaterialUVMapping(json: raw) else {
            return Self.fail("bad_mapping",
                             "mapping needs an object: source (mesh|planarProjection|boxProjection), "
                                + "axis (x|y|z), scale_mm [u,v], rotation_degrees, offset [u,v], flip_u, flip_v.")
        }
        guard let existing = lookupMaterial(args) else {
            return Self.fail("unknown_material", "mapping needs material_id or material.")
        }
        var definition = existing
        definition.uvMapping = map
        definition.revision += 1
        definition.updatedAt = Date()
        definition = definition.sanitized
        var library = self.library
        library.upsert(definition)
        var updatedBodies: [String] = []
        var appearance: SetMaterialAppearanceCommand?
        if Self.bool(args["apply_to_applied"]) ?? true {
            let spec = definition.bodyMaterialSpec()
            var snapshots: [BodyID: SetMaterialAppearanceCommand.Snapshot] = [:]
            for body in document.session.document.bodies {
                var material = body.material
                var bindings = body.materialFaceBindings
                var touched = false
                if material?.materialID == existing.id.raw.uuidString {
                    material = spec; touched = true
                }
                for index in bindings.indices
                where bindings[index].material.materialID == existing.id.raw.uuidString {
                    bindings[index].material = spec
                    touched = true
                }
                if touched {
                    snapshots[body.id] = .init(material: material, faceBindings: bindings)
                    updatedBodies.append(body.id.raw.uuidString)
                }
            }
            if !snapshots.isEmpty {
                appearance = SetMaterialAppearanceCommand(
                    title: "Material Mapping", bodyIDs: Set(snapshots.keys),
                    after: snapshots, document: document.session.document)
            }
        }
        if let failure = commitLibrary(library, appearance: appearance,
                                       title: "Material Mapping") { return failure }
        return Self.ok(["action": "mapping", "mutated": true,
                        "material": definition.summaryJSON,
                        "applied_bodies": updatedBodies.sorted(),
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    private func textures(_ args: [String: Any]) -> [String: Any] {
        guard let existing = lookupMaterial(args) else {
            return Self.fail("unknown_material", "textures needs material_id or material.")
        }
        guard let rawSlot = Self.string(args["slot"]),
              let slot = MaterialTextureSlot(rawValue: rawSlot) else {
            return Self.fail("bad_slot",
                             "slot must be one of "
                                + MaterialTextureSlot.allCases.map(\.rawValue).joined(separator: "|") + ".")
        }
        var definition = existing
        if Self.bool(args["remove"]) == true {
            definition.textures.removeAll { $0.slot == slot }
        } else {
            guard let texture = Self.texture(from: args, slot: slot) else {
                return Self.fail("bad_texture",
                                 "Supply base64 PNG/JPEG bytes (<= \(CADMaterialLimits.maximumTextureBytes) bytes) "
                                    + "or asset_base64; mime must be image/png or image/jpeg.")
            }
            definition.textures.removeAll { $0.slot == slot }
            definition.textures.append(texture)
        }
        definition.revision += 1
        definition.updatedAt = Date()
        definition = definition.sanitized
        var library = self.library
        library.upsert(definition)
        var updatedBodies: [String] = []
        var appearance: SetMaterialAppearanceCommand?
        if Self.bool(args["apply_to_applied"]) ?? true {
            let spec = definition.bodyMaterialSpec()
            var snapshots: [BodyID: SetMaterialAppearanceCommand.Snapshot] = [:]
            for body in document.session.document.bodies {
                var material = body.material
                var bindings = body.materialFaceBindings
                var touched = false
                if material?.materialID == existing.id.raw.uuidString {
                    material = spec; touched = true
                }
                for index in bindings.indices
                where bindings[index].material.materialID == existing.id.raw.uuidString {
                    bindings[index].material = spec
                    touched = true
                }
                if touched {
                    snapshots[body.id] = .init(material: material, faceBindings: bindings)
                    updatedBodies.append(body.id.raw.uuidString)
                }
            }
            if !snapshots.isEmpty {
                appearance = SetMaterialAppearanceCommand(
                    title: "Material Texture", bodyIDs: Set(snapshots.keys),
                    after: snapshots, document: document.session.document)
            }
        }
        if let failure = commitLibrary(library, appearance: appearance,
                                       title: "Material Texture") { return failure }
        return Self.ok(["action": "textures", "mutated": true,
                        "material": definition.summaryJSON,
                        "applied_bodies": updatedBodies.sorted(),
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    // MARK: - Library import/export

    private func libraryExport(_ args: [String: Any]) -> [String: Any] {
        let library = self.library
        guard let data = CADMaterialLibraryCodec.encode(library),
              let json = String(data: data, encoding: .utf8) else {
            return Self.fail("library_encode_failed", "The library could not be encoded.")
        }
        return Self.ok(["action": "libraryExport",
                        "schema_version": library.schemaVersion,
                        "count": library.entries.count,
                        "library_json": json,
                        "byte_count": data.count,
                        "note": "Bytes are encoded into the JSON; the host may store this shared library file."])
    }

    /// List a library payload (the shared/personal store injected by the host
    /// as library_json) without mutating this document. With no payload this
    /// is the same metadata as `list` for the document library.
    private func libraryList(_ args: [String: Any]) -> [String: Any] {
        guard let raw = Self.string(args["library_json"]) else { return list(args) }
        guard raw.utf8.count <= CADMaterialLimits.maximumLibraryBytes else {
            return Self.fail("library_too_large",
                             "library_json exceeds the personal-library size bound.")
        }
        guard let data = raw.data(using: .utf8) else {
            return Self.fail("bad_library", "library_json is not UTF-8 text.")
        }
        let library: CADMaterialLibrary
        if let decoded = try? JSONDecoder().decode(CADMaterialLibrary.self, from: data) {
            library = decoded.sanitized
        } else if let entries = try? JSONDecoder().decode([CADMaterialDefinition].self, from: data) {
            library = CADMaterialLibrary(entries: entries).sanitized
        } else {
            return Self.fail("bad_library", "library_json is not a CADMaterialLibrary or material array.")
        }
        return Self.ok(["action": "libraryList",
                        "schema_version": library.schemaVersion,
                        "count": library.entries.count,
                        "materials": library.entries.map(\.summaryJSON),
                        "byte_count": data.count])
    }

    private func libraryImport(_ args: [String: Any]) -> [String: Any] {
        var incoming: [CADMaterialDefinition] = []
        if let raw = Self.string(args["library_json"]) {
            guard raw.utf8.count <= CADMaterialLimits.maximumLibraryBytes else {
                return Self.fail("library_too_large",
                                 "library_json exceeds the personal-library size bound.")
            }
            guard let data = raw.data(using: .utf8) else {
                return Self.fail("bad_library", "library_json is not UTF-8 text.")
            }
            if let decoded = try? JSONDecoder().decode(CADMaterialLibrary.self, from: data) {
                incoming = decoded.entries
            } else if let entries = try? JSONDecoder().decode([CADMaterialDefinition].self, from: data) {
                incoming = entries
            } else {
                return Self.fail("bad_library", "library_json is not a CADMaterialLibrary or material array.")
            }
        } else if let rows = args["entries"] as? [[String: Any]] {
            guard JSONSerialization.isValidJSONObject(rows),
                  let data = try? JSONSerialization.data(withJSONObject: rows),
                  let entries = try? JSONDecoder().decode([CADMaterialDefinition].self, from: data) else {
                return Self.fail("bad_library", "entries must be material definitions with base64 texture bytes.")
            }
            incoming = entries
        } else {
            return Self.fail("missing_library", "libraryImport needs library_json or entries.")
        }
        guard !incoming.isEmpty else { return Self.fail("empty_library", "The imported library has no entries.") }
        guard incoming.count <= CADMaterialLimits.maximumLibraryEntries else {
            return Self.fail("library_too_large",
                             "At most \(CADMaterialLimits.maximumLibraryEntries) entries can be imported.")
        }
        var library = Self.bool(args["replace"]) == true ? CADMaterialLibrary() : self.library
        for entry in incoming {
            library.upsert(entry)
        }
        if let failure = writeLibrary(library) { return failure }
        return Self.ok(["action": "libraryImport", "mutated": true,
                        "imported": incoming.count,
                        "count": library.entries.count,
                        "entries": library.entries.map(\.summaryJSON),
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    // MARK: - Undo/redo (shared document stack)

    private func undo(_ args: [String: Any]) -> [String: Any] {
        guard document.session.undoStack.canUndo else {
            return Self.fail("nothing_to_undo", "The material/geometry undo stack is empty.")
        }
        document.session.undo()
        return Self.ok(["action": "undo", "mutated": true,
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    private func redo(_ args: [String: Any]) -> [String: Any] {
        guard document.session.undoStack.canRedo else {
            return Self.fail("nothing_to_redo", "The material/geometry redo stack is empty.")
        }
        document.session.redo()
        return Self.ok(["action": "redo", "mutated": true,
                        "revision": document.revision,
                        "change_count": document.session.changeCount,
                        "can_undo": document.session.undoStack.canUndo,
                        "can_redo": document.session.undoStack.canRedo])
    }

    // MARK: - Material construction

    /// Look up an entry by stable id or by display name.
    private func lookupMaterial(_ args: [String: Any]) -> CADMaterialDefinition? {
        let library = self.library
        if let raw = Self.string(args["material_id"]) ?? Self.string(args["id"]),
           let uuid = UUID(uuidString: raw) {
            return library.entry(MaterialID(raw: uuid))
        }
        if let name = Self.string(args["material"]) ?? Self.string(args["material_name"]) {
            if let uuid = UUID(uuidString: name), let entry = library.entry(MaterialID(raw: uuid)) {
                return entry
            }
            return library.entry(named: name)
        }
        return nil
    }

    /// A library entry, an inline definition built from color/maps fields, or
    /// nil when the caller supplied neither (a valid "just clear/remove" case
    /// for face reassignment). Inline application never silently adds a
    /// library entry. Malformed inline fields are a structured failure.
    private struct MaterialApplyError: Error {
        var reply: [String: Any]
    }

    private func materialForApply(_ args: [String: Any])
        -> Result<CADMaterialDefinition?, MaterialApplyError> {
        if let existing = lookupMaterial(args) { return .success(existing) }
        let hasInline = args["color"] != nil || args["base_color"] != nil
            || args["textures"] != nil || args["uv_mapping"] != nil
            || args["opacity"] != nil || args["metallic"] != nil
            || args["roughness"] != nil || args["emissive"] != nil
        guard hasInline else { return .success(nil) }
        let name = Self.string(args["name"]) ?? "Material"
        var definition = CADMaterialDefinition(name: name)
        if let failure = applyFields(args, to: &definition) {
            return .failure(MaterialApplyError(reply: failure))
        }
        return .success(definition.sanitized)
    }

    /// Applies the shared mutating argument vocabulary. Returns a failure
    /// dictionary on a malformed field.
    private func applyFields(_ args: [String: Any],
                             to definition: inout CADMaterialDefinition) -> [String: Any]? {
        if let raw = args["name"] ?? args["material_name"], let name = Self.string(raw) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return Self.fail("bad_name", "Material name must not be blank.")
            }
            definition.name = String(trimmed.prefix(120))
        }
        if let color = Self.rgba(args["color"] ?? args["base_color"]) {
            definition.baseColor = color
            definition.opacity = color.w
        } else if args["color"] != nil || args["base_color"] != nil {
            return Self.fail("bad_color",
                             "color/base_color must be [r,g,b] or [r,g,b,a] in 0…1 (or #RRGGBB/#RRGGBBAA).")
        }
        if let raw = args["metallic"] {
            guard let value = Self.number(raw), value.isFinite, (0...1).contains(value) else {
                return Self.fail("bad_metallic", "metallic must be a finite number in 0…1.")
            }
            definition.metallic = value
        }
        if let raw = args["roughness"] {
            guard let value = Self.number(raw), value.isFinite, (0...1).contains(value) else {
                return Self.fail("bad_roughness", "roughness must be a finite number in 0…1.")
            }
            definition.roughness = value
        }
        if let raw = args["opacity"] {
            guard let value = Self.number(raw), value.isFinite, (0...1).contains(value) else {
                return Self.fail("bad_opacity", "opacity must be a finite number in 0…1.")
            }
            definition.opacity = value
        }
        if let raw = args["emissive"] {
            guard let values = Self.doubles(raw), values.count == 3,
                  values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                return Self.fail("bad_emissive", "emissive must be [r,g,b] in 0…1.")
            }
            definition.emissive = SIMD3(values[0], values[1], values[2])
        }
        if let raw = args["emissive_strength"] ?? args["emissiveStrength"] {
            guard let value = Self.number(raw), value.isFinite, (0...100).contains(value) else {
                return Self.fail("bad_emissive_strength", "emissive_strength must be in 0…100.")
            }
            definition.emissiveStrength = value
        }
        if let raw = args["uv_mapping"] ?? args["uvMapping"] {
            guard let object = raw as? [String: Any],
                  let map = CADMaterialUVMapping(json: object) else {
                return Self.fail("bad_mapping", "uv_mapping must name source/axis/scale_mm/rotation/offset.")
            }
            definition.uvMapping = map
        }
        if let rawTextures = args["textures"] as? [[String: Any]] {
            for row in rawTextures {
                guard let rawSlot = Self.string(row["slot"]),
                      let slot = MaterialTextureSlot(rawValue: rawSlot) else {
                    return Self.fail("bad_slot", "Every texture needs slot = "
                        + MaterialTextureSlot.allCases.map(\.rawValue).joined(separator: "|") + ".")
                }
                if Self.bool(row["remove"]) == true {
                    definition.textures.removeAll { $0.slot == slot }
                    continue
                }
                guard let texture = Self.texture(from: row, slot: slot) else {
                    return Self.fail("bad_texture",
                                     "Texture '\(slot.rawValue)' needs valid PNG/JPEG base64 bytes "
                                        + "(<= \(CADMaterialLimits.maximumTextureBytes)).")
                }
                definition.textures.removeAll { $0.slot == slot }
                definition.textures.append(texture)
            }
        }
        return nil
    }

    /// Index-based face edits need the generation they were queried at (or
    /// explicit stable signatures). Existence of an index is not identity: a
    /// rebuild may reuse the same number for a different face.
    private func validateFaceGeneration(_ args: [String: Any],
                                        body: Body,
                                        indices: [Int]) -> [String: Any]? {
        let signatures = materialFaceSignatures(args)
        let rawToken = Self.string(args["query_token"])
            ?? Self.string(args["query_generation_token"])
        var tokenAccepted = false
        if let rawToken, !rawToken.isEmpty {
            if let generation = CADGeometryQueryGeneration.parse(rawToken),
               generation.scope == "faces",
               generation.matches(documentRevision: document.revision,
                                  changeCount: document.session.changeCount,
                                  bodyID: body.id.raw,
                                  meshRevision: body.meshRevision) {
                tokenAccepted = true
            } else if signatures.isEmpty {
                return Self.fail(
                    "requery_required",
                    "The faces query generation is stale or malformed. Re-query query kind=faces "
                        + "and pass its query_token, or pass the row's stable face_signatures.")
            }
        }
        if !signatures.isEmpty {
            guard body.brep != nil else {
                return Self.fail("mesh_body",
                                 "Stable face signatures require an analytic B-rep; use a whole-body material.")
            }
            let candidates = CADFaceMaterialResolver.candidates(for: body)
            for index in indices {
                guard let reference = signatures[index] else {
                    if tokenAccepted { continue }
                    return Self.fail(
                        "requery_required",
                        "face_signatures must include face \(index). Re-query query kind=faces and copy the current row.")
                }
                guard let face = candidates.first(where: { $0.index == index }),
                      let actual = face.signature else {
                    return Self.fail("unknown_face", "No analytic face \(index) on '\(body.name)'.")
                }
                let score = CADFaceMaterialResolver.score(reference, actual) ?? 0
                if score < CADFaceMaterialResolver.matchThreshold {
                    return Self.fail(
                        "stale_face_ref",
                        "The supplied signature for face \(index) no longer matches the body. "
                            + "Re-query query kind=faces before applying a material.")
                }
            }
            return nil
        }
        guard tokenAccepted else {
            return Self.fail(
                "requery_required",
                "An index-based face material needs the query generation or stable signatures. "
                    + "Re-query query kind=faces and pass query_token with the current index, "
                    + "or pass face_signatures. Index existence alone is not a stable face identity.")
        }
        return nil
    }

    private func materialFaceSignatures(_ args: [String: Any]) -> [Int: FaceSignature] {
        var result: [Int: FaceSignature] = [:]
        if let rows = args["face_signatures"] as? [[String: Any]] {
            let aligned = (args["faces"] as? [Int])
                ?? (args["faces"] as? [NSNumber])?.map(\.intValue) ?? []
            for (offset, row) in rows.enumerated() {
                let index = Self.intValue(row["index"])
                    ?? (offset < aligned.count ? aligned[offset] : nil)
                guard let index else { continue }
                let object = (row["signature"] as? [String: Any]) ?? row
                if let signature = CADFaceSignatureCodec.signature(from: object) {
                    result[index] = signature
                }
            }
        }
        if let single = args["face_signature"] as? [String: Any],
           let signature = CADFaceSignatureCodec.signature(from: single) {
            let index = Self.intValue(single["index"])
                ?? (args["faces"] as? [Int])?.first
                ?? (args["faces"] as? [NSNumber])?.first?.intValue
            if let index { result[index] = signature }
        }
        return result
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    // MARK: - Bodies

    private func resolveBodies(_ args: [String: Any]) -> [Body]? {
        var raws: [String] = []
        if let list = args["bodyIDs"] as? [String] { raws = list }
        else if let list = args["body_ids"] as? [String] { raws = list }
        else if let one = Self.string(args["bodyID"]) ?? Self.string(args["body_id"]) { raws = [one] }
        guard !raws.isEmpty else { return nil }
        let bodies = document.session.document.bodies
        var resolved: [Body] = []
        for raw in raws {
            let value = raw.lowercased().hasPrefix("body:")
                ? String(raw.dropFirst("body:".count)) : raw
            guard let uuid = UUID(uuidString: value),
                  let body = bodies.first(where: { $0.id.raw == uuid }) else { return nil }
            resolved.append(body)
        }
        return resolved
    }

    private func appliedBodyReferences(for id: MaterialID) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for body in document.session.document.bodies {
            let bodyLevel = body.material?.materialID == id.raw.uuidString
            let faceCount = body.materialFaceBindings.filter {
                $0.material.materialID == id.raw.uuidString
            }.count
            guard bodyLevel || faceCount > 0 else { continue }
            rows.append(["body_id": body.id.raw.uuidString,
                         "name": body.name,
                         "body_level": bodyLevel,
                         "face_bindings": faceCount])
        }
        return rows
    }

    private func mutationReply(action: String, material: CADMaterialDefinition?,
                               bodyIDs: [UUID], extra: [String: Any]) -> [String: Any] {
        var reply = extra
        reply["action"] = action
        reply["mutated"] = true
        if let material { reply["material"] = material.summaryJSON }
        reply["body_ids"] = bodyIDs.map(\.uuidString)
        reply["revision"] = document.revision
        reply["change_count"] = document.session.changeCount
        reply["can_undo"] = document.session.undoStack.canUndo
        reply["can_redo"] = document.session.undoStack.canRedo
        if action == "applyFaces" {
            reply["note"] = "Face appearances resolve from stable signatures; query kind=faces to confirm."
        }
        return reply
    }

    // MARK: - Argument helpers

    static func texture(from row: [String: Any],
                        slot: MaterialTextureSlot) -> CADMaterialTexture? {
        let raw = Self.string(row["base64"]) ?? Self.string(row["asset_base64"])
            ?? Self.string(row["bytes_base64"])
        guard let raw else { return nil }
        guard raw.utf8.count <= (CADMaterialLimits.maximumTextureBytes + 2) / 3 * 4 else { return nil }
        guard let data = Data(base64Encoded: raw), !data.isEmpty,
              data.count <= CADMaterialLimits.maximumTextureBytes,
              MaterialImageSniffer.mimeType(of: data) != nil else { return nil }
        let colorSpace = Self.string(row["color_space"]).flatMap {
            MaterialTextureColorSpace(rawValue: $0)
        }
        let orientation = Self.string(row["orientation"]).flatMap {
            MaterialTextureOrientation(rawValue: $0)
        } ?? .topLeft
        let mime = MaterialImageSniffer.normalizedMimeType(Self.string(row["mime_type"]))
        return CADMaterialTexture(slot: slot,
                                  name: Self.string(row["name"]),
                                  mimeType: mime,
                                  colorSpace: colorSpace,
                                  orientation: orientation,
                                  bytes: data)
    }

    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func doubles(_ value: Any?) -> [Double]? {
        if let values = value as? [Double] { return values }
        if let values = value as? [NSNumber] { return values.map(\.doubleValue) }
        if let values = value as? [Any] {
            var out: [Double] = []
            for element in values {
                guard let number = Self.number(element), number.isFinite else { return nil }
                out.append(number)
            }
            return out
        }
        return nil
    }

    /// [r,g,b(,a)] in 0…1, with #RRGGBB/#RRGGBBAA accepted for human calls.
    static func rgba(_ value: Any?) -> SIMD4<Double>? {
        if let values = Self.doubles(value) {
            guard values.count == 3 || values.count == 4,
                  values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            return SIMD4(values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
        }
        if let text = Self.string(value) {
            var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6 || hex.count == 8,
                  let raw = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? Double(raw & 0xFF) / 255 : 1
            return SIMD4(r, g, b, a)
        }
        return nil
    }

    static func vector(_ value: SIMD3<Double>) -> [Double] {
        [value.x, value.y, value.z]
    }

    static func ok(_ object: [String: Any]) -> [String: Any] {
        var reply = object
        reply["ok"] = true
        return reply
    }

    static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
}
