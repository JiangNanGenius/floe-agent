// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Stable preview identity. The previous installer used a random UUID for each
/// plan, so an apply that re-planned the same revision could never match its
/// preview. This identity covers every effect and is stable across calls.
enum GameDeveloperInstrumentationPlanIdentity {
    static func make(engine: GameEngineID,
                     context: GameProjectContext,
                     gameRoot: GameRelativePath?,
                     files: [GameDeveloperProjectInstrumentationFile],
                     scene: GameDeveloperInstrumentationScene?,
                     exportHandling: GameDeveloperInstrumentationExportHandling,
                     autoload: GameDeveloperGodotAutoloadPlan?) -> UUID {
        var lines: [String] = [
            "engine=\(engine.rawValue)",
            "project=\(context.projectID.uuidString)",
            "revision=\(context.savedRevision)",
            "environment=\(context.environmentID ?? "")",
            "root=\(gameRoot?.value ?? "")",
            "export=\(exportHandling.rawValue)",
            "scene=\(scene?.id ?? ""):\(scene?.path.value ?? "")",
            "autoload=\(autoload?.line ?? "")"
        ]
        for file in files.sorted(by: { $0.path.value < $1.path.value }) {
            lines.append("file=\(file.path.value)|\(file.kind.rawValue)|\(file.action.rawValue)"
                + "|\(file.templateResource)|\(file.outputSHA256)|\(file.existingSHA256 ?? "")")
        }
        let digest = GameDigest.sha256(Data(lines.joined(separator: "\n").utf8))
        let bytes = Array(digest.utf8)
        guard bytes.count == 32 else { return UUID() }
        let uuid = String(decoding: bytes[0..<8], as: UTF8.self) + "-"
            + String(decoding: bytes[8..<12], as: UTF8.self) + "-"
            + String(decoding: bytes[12..<16], as: UTF8.self) + "-"
            + String(decoding: bytes[16..<20], as: UTF8.self) + "-"
            + String(decoding: bytes[20..<32], as: UTF8.self)
        return UUID(uuidString: uuid) ?? UUID()
    }
}
