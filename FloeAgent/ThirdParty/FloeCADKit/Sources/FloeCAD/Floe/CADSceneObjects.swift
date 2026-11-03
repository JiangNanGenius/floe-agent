// SPDX-License-Identifier: MPL-2.0
// Hierarchy/identity only. Payload poses remain in bodies, assembly.json and
// the existing scene settings. A group alone owns a new local pose.
import Foundation
import simd

public nonisolated enum CADSceneObjectKind: String, Codable, Sendable, CaseIterable {
    case group, body, assembly, light, camera
}

public nonisolated struct CADSceneObjectLink: Codable, Equatable, Sendable, Identifiable {
    /// Payload references use the payload's UUID verbatim; groups mint one ID.
    public var id: UUID
    public var kind: CADSceneObjectKind
    public var parentID: UUID?
    public var groupName: String?
    public var groupTransform: CADTransform?

    public init(id: UUID, kind: CADSceneObjectKind, parentID: UUID? = nil,
                groupName: String? = nil, groupTransform: CADTransform? = nil) {
        self.id = id; self.kind = kind; self.parentID = parentID
        self.groupName = groupName; self.groupTransform = groupTransform
    }
}

public nonisolated struct CADSceneObjectHierarchy: Codable, Equatable, Sendable {
    public static let maximumCount = 4096
    public static let maximumDepth = 64
    public var version: Int = 1
    public var nodes: [CADSceneObjectLink] = []

    public init(nodes: [CADSceneObjectLink] = []) { self.nodes = nodes }

    func validate() throws {
        guard version == 1, nodes.count <= Self.maximumCount,
              Set(nodes.map(\.id)).count == nodes.count else { throw CADSceneObjectError.invalidHierarchy }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            if node.kind == .group {
                guard let name = node.groupName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.count <= 80, let pose = node.groupTransform, pose.isPlaceable,
                      (0..<3).allSatisfy({ abs(pose.position[$0]) <= 1e9 }),
                      (1e-9...1e9).contains(pose.scale.x) else {
                    throw CADSceneObjectError.invalidHierarchy
                }
            } else if node.groupName != nil || node.groupTransform != nil {
                throw CADSceneObjectError.invalidHierarchy // never a second payload pose/name
            }
            var seen: Set<UUID> = [node.id], parent = node.parentID
            while let id = parent {
                guard seen.count <= Self.maximumDepth, seen.insert(id).inserted,
                      let ancestor = byID[id], ancestor.kind == .group else {
                    throw CADSceneObjectError.invalidHierarchy
                }
                parent = ancestor.parentID
            }
        }
    }

    func groupWorlds() throws -> [UUID: CADTransform] {
        var byID: [UUID: CADSceneObjectLink] = [:]
        for node in nodes {
            guard byID.updateValue(node, forKey: node.id) == nil else { throw CADSceneObjectError.invalidHierarchy }
        }
        var result: [UUID: CADTransform] = [:], visiting = Set<UUID>()
        func resolve(_ id: UUID, depth: Int) throws -> CADTransform {
            if let cached = result[id] { return cached }
            guard depth <= Self.maximumDepth, visiting.insert(id).inserted,
                  let node = byID[id], node.kind == .group, let local = node.groupTransform else {
                throw CADSceneObjectError.invalidHierarchy
            }
            let parent = try node.parentID.map { try resolve($0, depth: depth + 1) } ?? .identity
            let pose = parent.concatenating(local)
            guard pose.isPlaceable else { throw CADSceneObjectError.invalidTransform }
            visiting.remove(id); result[id] = pose
            return pose
        }
        for node in nodes where node.kind == .group { _ = try resolve(node.id, depth: 0) }
        return result
    }

    func groupWorld(_ id: UUID?) throws -> CADTransform {
        guard let id else { return .identity }
        guard let pose = try groupWorlds()[id] else { throw CADSceneObjectError.invalidHierarchy }
        return pose
    }

    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        for _ in 0..<Self.maximumDepth {
            let next = Set(nodes.filter { $0.parentID.map(result.contains) == true }.map(\.id))
            let merged = result.union(next)
            if merged == result { break }
            result = merged
        }
        return result
    }
}

nonisolated enum CADSceneObjectError: String, Error, LocalizedError {
    case invalidHierarchy = "invalid_scene_hierarchy"
    case invalidTransform = "invalid_scene_transform"
    case missingObject = "scene_object_missing"
    case referenced = "scene_object_referenced"
    case assemblyParent = "assembly_parent_owned"
    case definitionScope = "definition_placement_scope"
    case placementDependency = "scene_placement_dependency"
    case cameraRoll = "camera_transform_unsupported"
    case cancelled = "scene_edit_cancelled"
    case failed = "scene_edit_failed"
    case resourceLimit = "scene_resource_budget"
    var errorDescription: String? {
        switch self {
        case .invalidHierarchy: FloeCADStrings.text("cad.scene.invalidHierarchy", "The object hierarchy is invalid or too large.")
        case .invalidTransform: FloeCADStrings.text("cad.scene.invalidTransform", "Use a finite position, rotation and positive uniform scale.")
        case .missingObject: FloeCADStrings.text("cad.scene.missing", "This object is no longer available.")
        case .referenced: FloeCADStrings.text("cad.scene.referenced", "Detach this object from its group before deleting it.")
        case .assemblyParent: FloeCADStrings.text("cad.scene.assemblyParent", "Move nested parts through the assembly hierarchy first.")
        case .definitionScope: FloeCADStrings.text("cad.scene.definitionScope", "Move the placed assembly part instead of its shared definition.")
        case .placementDependency: FloeCADStrings.text("cad.scene.placementDependency", "Later model features depend on this placement. Edit those features before moving the group.")
        case .cameraRoll: FloeCADStrings.text("cad.scene.cameraRoll", "This saved camera cannot represent that rotation or scale.")
        case .cancelled: FloeCADStrings.text("cad.scene.cancelled", "The scene edit was cancelled.")
        case .resourceLimit: FloeCADStrings.text("cad.scene.resourceLimit", "Read fewer object resources at once.")
        case .failed: FloeCADStrings.text("cad.scene.failed", "The scene edit could not be applied.")
        }
    }
}

nonisolated enum CADSceneObjectCodec {
    static func hierarchy(_ data: Data?) throws -> CADSceneObjectHierarchy {
        guard let data else { return .init() }
        // Strict raw key validation preserves unknown/future intent read-only.
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CADSceneObjectError.invalidHierarchy
        }
        guard let raw = root["sceneObjects"], !(raw is NSNull) else { return .init() }
        guard let row = raw as? [String: Any], Set(row.keys).isSubset(of: ["version", "nodes"]),
              let nodes = row["nodes"] as? [[String: Any]],
              nodes.allSatisfy({ node in
                  guard Set(node.keys).isSubset(of: ["id", "kind", "parentID", "groupName", "groupTransform"]) else { return false }
                  if let pose = node["groupTransform"], !(pose is NSNull) {
                      guard let value = pose as? [String: Any], Set(value.keys).isSubset(of: ["position", "rotation", "scale"]) else { return false }
                  }
                  return true
              }) else {
            throw CADSceneObjectError.invalidHierarchy
        }
        let graph = try JSONDecoder().decode(CADSceneObjectHierarchy.self,
                                             from: JSONSerialization.data(withJSONObject: row))
        try graph.validate()
        return graph
    }

    static func inverse(_ pose: CADTransform) throws -> CADTransform {
        guard pose.isPlaceable else { throw CADSceneObjectError.invalidTransform }
        let q = simd_normalize(simd_quatd(vector: pose.rotation)).inverse
        return CADTransform(position: q.act(-pose.position) / pose.scale.x, rotation: q.vector,
                            scale: SIMD3(repeating: 1 / pose.scale.x))
    }

    static func pose(_ value: Transform3D) -> CADTransform {
        CADTransform(position: value.translation, rotation: value.rotation.vector,
                     scale: SIMD3(repeating: value.scale))
    }

    /// Stable, disjoint-by-domain history identity. A collision is refused by
    /// the service, never overwritten. Detach/reparent/reopen reuses this node.
    static func placementID(_ bodyID: UUID) -> FeatureID {
        let hash = CADMaterialTexture.digest(Data(("floe.scene.placement.v1:" + bodyID.uuidString).utf8))
        let hex = String(hash.prefix(32))
        let pieces = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return FeatureID(raw: UUID(uuidString: pieces.joined(separator: "-"))!)
    }

    static func transformJSON(_ value: CADTransform) -> [String: Any] {
        ["position": [value.position.x, value.position.y, value.position.z],
         "rotation": [value.rotation.x, value.rotation.y, value.rotation.z, value.rotation.w],
         "scale": [value.scale.x, value.scale.y, value.scale.z]]
    }

    /// Deletion protection at the existing DocumentSession transaction gate.
    /// Only metadata/removal commands are inspected; never run kernel command
    /// apply twice to simulate a transaction. The final hierarchy blob is used
    /// so one composite may explicitly detach a reference and delete it.
    @MainActor
    static func deletionFailure(commands: [DocumentCommand], document: DesignDocument) -> CADSceneObjectError? {
        func canDeleteReference(_ command: DocumentCommand) -> Bool {
            if let value = command as? CompositeCommand { return value.commands.contains(where: canDeleteReference) }
            return command is SetSceneSettingsDataCommand || command is SetAssemblyDataCommand
                || command is DeleteBodiesCommand || command is RemoveFeatureCommand
                || command is SetFeatureSuppressedCommand
        }
        guard commands.contains(where: canDeleteReference) else { return nil }
        guard let data = document.sceneSettingsData,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intent = root["sceneObjects"], !(intent is NSNull) else { return nil }
        guard let original = try? hierarchy(data) else { return .invalidHierarchy }
        guard !original.nodes.isEmpty else { return nil }
        var settings = document.sceneSettingsData, assemblyData = document.assemblyData
        var deletedBodies = Set<BodyID>(), deletedFeatures = Set<FeatureID>()
        func inspect(_ command: DocumentCommand) {
            if let composite = command as? CompositeCommand { composite.commands.forEach(inspect) }
            else if let change = command as? SetSceneSettingsDataCommand { settings = change.after }
            else if let change = command as? SetAssemblyDataCommand { assemblyData = change.after }
            else if let change = command as? DeleteBodiesCommand { deletedBodies.formUnion(change.removed.map(\.body.id)) }
            else if let change = command as? RemoveFeatureCommand { deletedFeatures.insert(change.node.id) }
            else if let change = command as? SetFeatureSuppressedCommand, change.after { deletedFeatures.insert(change.featureID) }
        }
        commands.forEach(inspect)
        guard let graph = try? hierarchy(settings) else { return .invalidHierarchy }
        let scene = settings.flatMap { try? JSONDecoder().decode(CADSceneSettings.self, from: $0) }
        let assembly = try? CADAssembly.decode(from: assemblyData)
        for node in graph.nodes {
            switch node.kind {
            case .group: break
            case .body:
                if deletedBodies.contains(BodyID(raw: node.id)) || deletedFeatures.contains(placementID(node.id)) { return .referenced }
            case .assembly:
                if assembly?.instance(node.id) == nil { return .referenced }
                if node.parentID != nil, assembly?.parentInstanceID(of: node.id) != nil { return .assemblyParent }
            case .light:
                if scene?.presentation?.sceneLights?.contains(where: { $0.id == node.id }) != true { return .referenced }
            case .camera:
                if scene?.savedCameras?.contains(where: { $0.id == node.id }) != true { return .referenced }
            }
        }
        return nil
    }
}
