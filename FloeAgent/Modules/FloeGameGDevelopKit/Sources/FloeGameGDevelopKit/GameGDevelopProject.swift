// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameGDevelopError: Error, Equatable, Sendable {
    case invalidProject(String)
    case invalidVersion(String)
    case invalidInput(String)
    case unsafePath(String)
    case unreadable(String)
    case limitExceeded(String)
    case duplicate(String)
    case exportPlanInvalid(String)
    case artifactIncomplete(String)
    case artifactMismatch(String)
    case sdkMismatch(String)
    case io(String)
}

/// The `gdVersion` object written by official GDevelop Core.
public struct GameGDevelopProjectVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let revision: Int
    public let build: Int

    public init(major: Int = 5, minor: Int = 6, revision: Int = 0, build: Int) {
        self.major = major
        self.minor = minor
        self.revision = revision
        self.build = build
    }

    public var display: String { "\(major).\(minor).\(revision) build \(build)" }
}

public struct GameGDevelopSceneSummary: Codable, Equatable, Sendable {
    public let name: String
    public let objectNames: [String]
    public let instanceCount: Int
    public let eventCount: Int
    public let resources: [String]
}

public struct GameGDevelopResourceSummary: Codable, Equatable, Sendable {
    public let name: String
    public let file: String
    public let kind: String
    /// Filled by the source-tree inspector; a document alone cannot know.
    public let fileExists: Bool?
}

public struct GameGDevelopProjectSummary: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let projectUUID: String
    public let version: GameGDevelopProjectVersion
    public let firstLayout: String
    public let scenes: [GameGDevelopSceneSummary]
    public let resources: [GameGDevelopResourceSummary]
    /// Object types and instruction prefixes referenced by the project. These
    /// are metadata for extension bundling; they do not register an adapter.
    public let extensionTypes: [String]
    public let propertyKeys: [String]
    public let sourceBytes: Int
    public let sourceSHA256: String

    public var isStandardGDJSProject: Bool {
        !name.isEmpty && !scenes.isEmpty && scenes.contains(where: { $0.name == firstLayout })
    }
}

/// A standard GDevelop project JSON document. The original bytes are kept so
/// import/organization cannot silently lose unknown fields. Typed edits encode
/// a new document; they never rewrite the repository's immutable source.
public struct GameGDevelopProjectDocument: Sendable {
    public let rawData: Data
    public let summary: GameGDevelopProjectSummary

    public init(data: Data) throws {
        guard data.count > 0, data.count <= 64 * 1_024 * 1_024 else {
            throw GameGDevelopError.limitExceeded("projectJSON")
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GameGDevelopError.invalidProject("root is not a JSON object")
            }
            object = parsed
        } catch let error as GameGDevelopError {
            throw error
        } catch {
            throw GameGDevelopError.invalidProject("malformed JSON")
        }
        self.rawData = data
        self.summary = try Self.summarize(object, sourceBytes: data.count, sourceSHA256: GameDigest.sha256(data))
    }

    public func encoded() -> Data { rawData }

    /// GDevelop key names used by `KeyPressed` conditions in the source.
    /// This reads the standard event schema and never executes event code.
    public func keyboardKeys() -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else { return [] }
        var keys = Set<String>()
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let type = dictionary["type"] as? [String: Any],
                   (type["value"] as? String) == "KeyPressed",
                   let parameters = dictionary["parameters"] as? [Any],
                   parameters.count >= 2, let key = parameters[1] as? String {
                    keys.insert(key.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(root["layouts"] ?? [])
        return keys.sorted()
    }

    /// Renames only `properties.name`; all unknown fields, resources, events
    /// and plugin data remain in the document.
    public func replacingProjectName(_ name: String) throws -> GameGDevelopProjectDocument {
        guard Self.validText(name) else { throw GameGDevelopError.invalidProject("project name") }
        return try Self.mutating(rawData) { root in
            guard var properties = root["properties"] as? [String: Any] else {
                throw GameGDevelopError.invalidProject("properties")
            }
            properties["name"] = name
            root["properties"] = properties
        }
    }

    public func replacingProjectUUID(_ uuid: UUID) throws -> GameGDevelopProjectDocument {
        try Self.mutating(rawData) { root in
            guard var properties = root["properties"] as? [String: Any] else {
                throw GameGDevelopError.invalidProject("properties")
            }
            properties["projectUuid"] = uuid.uuidString.lowercased()
            root["properties"] = properties
        }
    }

    /// Moves one initial instance in a named scene. This is the smallest
    /// useful AI edit and preserves every other field in the project.
    public func movingInstance(scene: String, object: String, x: Double, y: Double) throws -> GameGDevelopProjectDocument {
        guard x.isFinite, y.isFinite, abs(x) <= 10_000_000, abs(y) <= 10_000_000 else {
            throw GameGDevelopError.invalidInput("instance position")
        }
        return try Self.mutating(rawData) { root in
            guard var layouts = root["layouts"] as? [[String: Any]],
                  let layoutIndex = layouts.firstIndex(where: { ($0["name"] as? String) == scene }) else {
                throw GameGDevelopError.invalidProject("scene \(scene)")
            }
            var layout = layouts[layoutIndex]
            guard var instances = layout["instances"] as? [[String: Any]],
                  let instanceIndex = instances.firstIndex(where: { ($0["name"] as? String) == object }) else {
                throw GameGDevelopError.invalidProject("instance \(object) in \(scene)")
            }
            var instance = instances[instanceIndex]
            instance["x"] = x
            instance["y"] = y
            instances[instanceIndex] = instance
            layout["instances"] = instances
            layouts[layoutIndex] = layout
            root["layouts"] = layouts
        }
    }

    private static func mutating(_ data: Data, _ body: (inout [String: Any]) throws -> Void) throws -> Self {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameGDevelopError.invalidProject("root")
        }
        try body(&root)
        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw GameGDevelopError.invalidProject("encode")
        }
        return try Self(data: encoded)
    }

    private static func summarize(_ root: [String: Any], sourceBytes: Int, sourceSHA256: String) throws -> GameGDevelopProjectSummary {
        guard let versionObject = root["gdVersion"] as? [String: Any],
              let major = int(versionObject["major"]), let minor = int(versionObject["minor"]),
              let revision = int(versionObject["revision"]), let build = int(versionObject["build"]),
              major >= 3, major <= 9, minor >= 0, minor <= 99, revision >= 0, build >= 0 else {
            throw GameGDevelopError.invalidVersion("gdVersion")
        }
        guard let properties = root["properties"] as? [String: Any],
              let name = properties["name"] as? String, validText(name) else {
            throw GameGDevelopError.invalidProject("properties.name")
        }
        let uuid = (properties["projectUuid"] as? String) ?? ""
        guard uuid.isEmpty || UUID(uuidString: uuid) != nil else {
            throw GameGDevelopError.invalidProject("properties.projectUuid")
        }
        guard let layouts = root["layouts"] as? [[String: Any]] else {
            throw GameGDevelopError.invalidProject("layouts")
        }
        let firstLayout = (root["firstLayout"] as? String) ?? ""
        var sceneNames = Set<String>()
        var scenes: [GameGDevelopSceneSummary] = []
        for layout in layouts {
            guard let sceneName = layout["name"] as? String, validText(sceneName),
                  sceneNames.insert(sceneName).inserted else {
                throw GameGDevelopError.invalidProject("layout name")
            }
            let objects = (layout["objects"] as? [[String: Any]]) ?? []
            let objectNames = objects.compactMap { $0["name"] as? String }
            let instances = (layout["instances"] as? [[String: Any]]) ?? []
            let events = (layout["events"] as? [[String: Any]]) ?? []
            let usedResources = (layout["usedResources"] as? [[String: Any]]) ?? []
            scenes.append(.init(name: sceneName,
                                objectNames: objectNames,
                                instanceCount: instances.count,
                                eventCount: events.count,
                                resources: usedResources.compactMap { $0["name"] as? String }.sorted()))
        }
        guard layouts.isEmpty || sceneNames.contains(firstLayout) else {
            throw GameGDevelopError.invalidProject("firstLayout")
        }
        let resourcesObject = (root["resources"] as? [String: Any])?["resources"] as? [[String: Any]] ?? []
        let resources = resourcesObject.map { item in
            GameGDevelopResourceSummary(
                name: item["name"] as? String ?? "",
                file: item["file"] as? String ?? "",
                kind: item["kind"] as? String ?? "unknown",
                fileExists: nil)
        }
        let types = extensionTypes(in: root)
        return .init(name: name,
                     description: properties["description"] as? String ?? "",
                     projectUUID: uuid,
                     version: .init(major: major, minor: minor, revision: revision, build: build),
                     firstLayout: firstLayout,
                     scenes: scenes,
                     resources: resources,
                     extensionTypes: types,
                     propertyKeys: properties.keys.sorted(),
                     sourceBytes: sourceBytes,
                     sourceSHA256: sourceSHA256)
    }

    /// Uses the project's own object/instruction type strings only. It never
    /// downloads, loads or executes an extension.
    private static func extensionTypes(in root: [String: Any]) -> [String] {
        var types = Set<String>()
        func add(_ value: Any?) {
            guard let text = value as? String, !text.isEmpty else { return }
            types.insert(text)
        }
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for key in ["type", "value"] { add(dictionary[key]) }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            } else {
                add(value)
            }
        }
        walk(root["layouts"] ?? [])
        return types.filter { $0.contains("::") || ["Sprite", "TextObject", "TileMap"].contains($0) }.sorted()
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double, value.rounded() == value { return Int(value) }
        return nil
    }

    static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
