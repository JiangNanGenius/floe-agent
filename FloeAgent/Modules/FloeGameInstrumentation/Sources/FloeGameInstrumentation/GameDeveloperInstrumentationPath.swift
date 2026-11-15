// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

enum GameDeveloperInstrumentationPath {
    static func resolve(_ root: GameRelativePath?, _ relative: String) throws -> GameRelativePath {
        guard let root else { return try GameRelativePath(relative) }
        guard !relative.isEmpty else { return root }
        return try GameRelativePath(root.value + "/" + relative)
    }

    static func prefix(_ root: GameRelativePath?) -> String {
        guard let root else { return "" }
        return root.value + "/"
    }

    static func relative(_ path: GameRelativePath, prefix: String) -> String {
        guard path.value.hasPrefix(prefix) else { return path.value }
        return String(path.value.dropFirst(prefix.count))
    }

    /// Same folded identity used by FileGameProjectRepository.validate.
    static func folded(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}
