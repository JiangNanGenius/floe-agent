// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct RGSSImportedProject: Sendable {
    public let project: GameStoredProject
    public let inspection: RGSSProjectInspection?
    public let warnings: [String]
    public init(project: GameStoredProject, inspection: RGSSProjectInspection?, warnings: [String]) {
        self.project = project; self.inspection = inspection; self.warnings = warnings
    }
}

public enum RGSSTemplateProvider {
    public static func files(for engine: GameEngineID) throws -> [GameFileChange] {
        let profile = try RGSSEngineProfiles.profile(for: engine)
        let folder: String
        let scriptResource: String
        switch engine {
        case .rpgMakerXP: folder = "XP"; scriptResource = "Scripts.rxdata"
        case .rpgMakerVX: folder = "VX"; scriptResource = "Scripts.rvdata"
        case .rpgMakerVXAce: folder = "VXAce"; scriptResource = "Scripts.rvdata2"
        default: throw RGSSRuntimeError.invalidEngine(engine.rawValue)
        }
        let base = "Resources/Templates/" + folder
        let gameIni = try resource("Game.ini", subdirectory: base)
        let marker = try resource("Game." + profile.markerExtension, subdirectory: base)
        let scripts = try resource(scriptResource, subdirectory: base)
        let inputs = try RGSSInputDeclaration.standard(for: engine).jsonData()
        return [
            .write(try GameRelativePath("Game.ini"), gameIni),
            .write(try GameRelativePath("Game." + profile.markerExtension), marker),
            .write(try GameRelativePath(profile.scriptsPath), scripts),
            .write(try GameRelativePath("floe-inputs.json"), inputs)
        ]
    }

    /// Creates a real empty repository project first, then commits the original
    /// template. There is no second original and no App/UI integration.
    public static func createProject(engine: GameEngineID, title: String, projectID: UUID,
                                     owner: GameProjectOwner,
                                     repository: FileGameProjectRepository) async throws -> GameStoredProject {
        guard RGSSEngineProfiles.isRGSS(engine) else { throw RGSSRuntimeError.invalidEngine(engine.rawValue) }
        let empty = try await repository.createProject(projectID: projectID, owner: owner,
                                                       title: title, engine: engine)
        let changes = try files(for: engine)
        return try await repository.commit(projectID, owner: owner,
                                           expectedRevision: empty.revision, changes: changes, title: title)
    }

    private static func resource(_ name: String, subdirectory: String) throws -> Data {
        let data = try RGSSHarnessResources.read(name, subdirectory: subdirectory)
        guard !data.isEmpty else { throw RGSSRuntimeError.io("empty template resource \(name)") }
        return data
    }
}

/// The settled import flow for every engine: create the repository project
/// first, import the entire original tree, then identify/organize. Unknown,
/// hidden, multi-root and plugin files are never pruned. The inspection is
/// informational and cannot block the import.
public struct RGSSProjectImporter: Sendable {
    public init() {}

    public func createAndImport(from source: URL, projectID: UUID, owner: GameProjectOwner,
                                title: String,
                                repository: FileGameProjectRepository) async throws -> RGSSImportedProject {
        let empty = try await repository.createProject(projectID: projectID, owner: owner,
                                                       title: title, engine: nil)
        let imported = try await repository.importContents(
            from: source, into: projectID, owner: owner,
            expectedRevision: empty.revision, replaceExisting: false)
        var inspection: RGSSProjectInspection?
        var warnings: [String] = []
        do {
            inspection = try RGSSCompatibilityInspector().inspect(rootURL: source)
        } catch {
            warnings.append("Import completed, but the RGSS project was not recognized: \(String(describing: error))")
        }
        return .init(project: imported, inspection: inspection, warnings: warnings)
    }

    /// Applies the original template to an already-created empty project, using
    /// the caller's saved revision. Never guesses a project or revision.
    public func applyTemplate(engine: GameEngineID, projectID: UUID, owner: GameProjectOwner,
                              expectedRevision: String, title: String?,
                              repository: FileGameProjectRepository) async throws -> GameStoredProject {
        let changes = try RGSSTemplateProvider.files(for: engine)
        return try await repository.commit(projectID, owner: owner,
                                           expectedRevision: expectedRevision,
                                           changes: changes, title: title)
    }
}
