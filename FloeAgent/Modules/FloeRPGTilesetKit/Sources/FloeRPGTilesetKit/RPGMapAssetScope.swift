// SPDX-License-Identifier: MPL-2.0
import FloeGameCore
import FloeRPGCore

/// The data and artwork of a map are resolved relative to its game, including
/// the www payload in a packaged MV/MZ project.
public struct RPGMapAssetScope: Sendable {
    private let prefix: String
    private let engine: RPGEngine

    public init?(map: GameRelativePath, engine: RPGEngine) {
        let parts = map.value.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2].lowercased() == "data",
              let name = parts.last?.lowercased() else { return nil }
        let suffix = "." + (engine.marshalExtension ?? "json")
        guard name.hasPrefix("map"), name.hasSuffix(suffix) else { return nil }
        let number = name.dropFirst(3).dropLast(suffix.count)
        guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let root = parts.dropLast(2).joined(separator: "/")
        prefix = root.isEmpty ? "" : root + "/"
        self.engine = engine
    }

    public func belongs(to selectedRoot: GameRelativePath?) -> Bool {
        let selected = selectedRoot.map { $0.value + "/" } ?? ""
        return prefix == selected || (engine.usesJSONData && prefix.hasPrefix(selected)
            && prefix.dropFirst(selected.count).lowercased() == "www/")
    }

    public func assetPath(for path: GameRelativePath) -> GameRelativePath? {
        guard path.value.hasPrefix(prefix) else { return nil }
        let local = String(path.value.dropFirst(prefix.count))
        guard let directory = local.split(separator: "/").first?.lowercased(),
              ["data", "img", "graphics"].contains(directory) else { return nil }
        return try? GameRelativePath(local)
    }

    public func repositoryPath(for asset: GameRelativePath) throws -> GameRelativePath {
        try GameRelativePath(prefix + asset.value)
    }
}
