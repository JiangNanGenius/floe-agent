// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import FloeGameCore

/// JSON syntax plus the original Web/Godot starter's small editable schema.
/// Engine-native validation is additive through GameAuthoringValidator adapters.
public struct GameJSONValidator: GameAuthoringValidator {
    public init() {}
    public func validate(_ source: GameAuthoringSource) async throws -> [GameAuthoringDiagnostic] {
        var diagnostics: [GameAuthoringDiagnostic] = []
        for file in source.project.files where file.path.value.hasSuffix(".json") {
            try Task.checkCancellation()
            if file.bytes > 8_388_608 { diagnostics.append(.init(.warning, path: file.path, message: "JSON file exceeds this validator's size limit")); continue }
            let bytes = try await source.read(file.path)
            do {
                let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
                if ["game.json", "game-config.json"].contains(file.path.value) {
                    guard let config = object as? [String: Any], let title = config["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let speed = config["speed"] as? NSNumber, CFGetTypeID(speed) != CFBooleanGetTypeID(), speed.doubleValue.isFinite,
                          (20...600).contains(speed.doubleValue) else {
                        diagnostics.append(.init(.error, path: file.path, message: "Game title and speed (20–600) are required")); continue
                    }
                }
            } catch { diagnostics.append(.init(.error, path: file.path, message: "Invalid JSON: \(error.localizedDescription)")) }
        }
        return diagnostics
    }
}
