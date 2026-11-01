// FloeWorkbench — Migration from the legacy single-asset media editor.

import Foundation
import FloeCore

public enum MigrationSupport {
    /// Produces honest recovery warnings without discarding anything.
    public static func recoveryWarnings(for project: MediaProject) -> [String] {
        var warnings: [String] = project.recoveryWarnings
        if project.schemaVersion > MediaProject.currentSchemaVersion {
            warnings.append("This project was created by a newer version of Floe (schema \(project.schemaVersion)); some features may be unavailable. Unknown operations were preserved.")
        }
        let missing = project.assets.filter { $0.relativePath.isEmpty }
        if !missing.isEmpty {
            warnings.append("\(missing.count) asset reference(s) have no path and need relinking.")
        }
        if !project.unknownOperations.isEmpty {
            warnings.append("\(project.unknownOperations.count) operation(s) from a newer version were preserved but cannot be edited in this version.")
        }
        return warnings
    }

    /// Migrates the legacy single-asset parameter JSON shape (`VideoEditPlan`
    /// persisted by MediaEditorView) into the unified project. Only operations
    /// this build understands are translated; anything else is recorded as an
    /// `UnknownOperation` and reported, never silently dropped. The migration
    /// is intentionally decoupled from FloeMedia types so it stays testable.
    public static func migrateLegacyPlan(id: UUID = UUID(), name: String,
                                         sourceRelativePath: String, data: Data) throws -> MediaProject {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rawOperations = json["operations"] as? [[String: Any]] ?? []
        let asset = MediaAssetReference(kind: .video, relativePath: sourceRelativePath,
                                        originalName: (sourceRelativePath as NSString).lastPathComponent)
        var project = MediaProject(id: id, kind: .video, name: name,
                                   assets: [asset], sourceAssetID: asset.id)
        project.recoveryWarnings.append("Migrated from the single-asset media editor.")
        for raw in rawOperations {
            guard let opName = raw["op"] as? String ?? raw.keys.first else { continue }
            let opData = try JSONSerialization.data(withJSONObject: raw)
            switch opName {
            case "trim":
                if let start = raw["start"] as? Double, let end = raw["end"] as? Double {
                    let clip = VideoClip(assetID: asset.id, trimStart: start, trimEnd: end)
                    project.videoTimeline = VideoTimeline(clips: [clip])
                }
            case "speed":
                if let rate = raw["rate"] as? Double,
                   let index = project.videoTimeline?.clips.indices.first {
                    project.videoTimeline?.clips[index].speed = rate
                }
            default:
                project.unknownOperations.append(UnknownOperation(kind: opName, payload: opData))
                project.recoveryWarnings.append("Legacy operation '\(opName)' was preserved but is not editable in this version.")
            }
        }
        if project.videoTimeline == nil {
            project.videoTimeline = VideoTimeline(clips: [VideoClip(assetID: asset.id, trimStart: 0, trimEnd: 0)])
            project.recoveryWarnings.append("Set the clip duration after migration.")
        }
        return project
    }
}
