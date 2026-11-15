// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Narrow consumption seam for the separately supplied
/// `FloeGameInstrumentation` package. This overlay deliberately does not
/// reimplement its Unity/Godot/GDevelop/Cocos source-hook installer or its
/// templates.
///
/// The App adapter supplies a concrete implementation backed by
/// `GameDeveloperProjectInstrumenter`; until that package is adopted the seam
/// reports `.unavailable` instead of fabricating hook files or a successful
/// development menu.
public struct GameInstrumentationSceneChoice: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let isStartScene: Bool

    public init(id: String, path: String, name: String, isStartScene: Bool) {
        self.id = id
        self.path = path
        self.name = name
        self.isStartScene = isStartScene
    }
}

public struct GameInstrumentationPlanSummary: Equatable, Sendable {
    public let planID: UUID
    public let engine: GameEngineID
    public let gameRoot: String
    public let catalogVersion: String?
    public let changedPaths: [String]
    public let unchangedPaths: [String]
    public let requiresRebuild: Bool
    public let dormancyGated: Bool
    public let scene: GameInstrumentationSceneChoice?
    public let scenes: [GameInstrumentationSceneChoice]
    public let exportHandling: String?
    public let capabilities: [String]
    public let diagnostics: [String]

    public init(planID: UUID, engine: GameEngineID, gameRoot: String, catalogVersion: String?,
                changedPaths: [String], unchangedPaths: [String],
                requiresRebuild: Bool, dormancyGated: Bool,
                scene: GameInstrumentationSceneChoice?, scenes: [GameInstrumentationSceneChoice],
                exportHandling: String?, capabilities: [String], diagnostics: [String]) {
        self.planID = planID
        self.engine = engine
        self.gameRoot = gameRoot
        self.catalogVersion = catalogVersion
        self.changedPaths = changedPaths
        self.unchangedPaths = unchangedPaths
        self.requiresRebuild = requiresRebuild
        self.dormancyGated = dormancyGated
        self.scene = scene
        self.scenes = scenes
        self.exportHandling = exportHandling
        self.capabilities = capabilities
        self.diagnostics = diagnostics
    }

    public var hasChanges: Bool { !changedPaths.isEmpty }
}

public struct GameInstrumentationApplyReceipt: Equatable, Sendable {
    public let projectID: UUID
    public let previousRevision: String
    public let revision: String
    public let changedPaths: [String]
    public let unchangedPaths: [String]
    public let sourceBundleManifestSHA256: String?
    public let requiresRebuild: Bool

    public init(projectID: UUID, previousRevision: String, revision: String,
                changedPaths: [String], unchangedPaths: [String],
                sourceBundleManifestSHA256: String?, requiresRebuild: Bool) {
        self.projectID = projectID
        self.previousRevision = previousRevision
        self.revision = revision
        self.changedPaths = changedPaths
        self.unchangedPaths = unchangedPaths
        self.sourceBundleManifestSHA256 = sourceBundleManifestSHA256
        self.requiresRebuild = requiresRebuild
    }
}

public enum GameInstrumentationSeamError: Error, Equatable, LocalizedError {
    case unavailable
    case unsupportedEngine(GameEngineID)
    case staleContext
    case dormancyUnverified

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The reviewed development-hook installer is not available in this build."
        case .unsupportedEngine(let engine):
            return "\(engine.rawValue) does not use the reviewed project source-hook installer."
        case .staleContext:
            return "The project changed while the development-hook plan was open. Reopen the current saved revision."
        case .dormancyUnverified:
            return "The installed development hooks are not proven dormant. The export was blocked."
        }
    }
}

/// Implemented by the App adapter over the separately delivered
/// `FloeGameInstrumentation` API. All methods must use the shared project
/// repository and its CAS; no second file writer is allowed.
public protocol GameInstrumentationConsuming: Sendable {
    /// Real scene choices from project metadata. Unity/Godot/GDevelop return
    /// an empty array; Cocos returns its scenes and actual startScene.
    func scenes(context: GameProjectContext, engine: GameEngineID,
                gameRoot: GameRelativePath?) async throws -> [GameInstrumentationSceneChoice]
    /// Preview only. It must not write the working tree or a repository.
    /// `sceneID` is required only for a multi-scene Cocos project without a
    /// startScene; the UI or AI must pass the user's explicit choice.
    func plan(context: GameProjectContext, engine: GameEngineID,
              gameRoot: GameRelativePath?, sceneID: String?) async throws -> GameInstrumentationPlanSummary
    /// Apply the exact previewed plan through the existing repository CAS.
    func apply(context: GameProjectContext, plan: GameInstrumentationPlanSummary,
               expectedRevision: String) async throws -> GameInstrumentationApplyReceipt
    /// Source bundle for distribution. It is not a signed installer.
    func sourceBundle(context: GameProjectContext,
                      plan: GameInstrumentationPlanSummary) async throws -> Data
}

/// Honest placeholder used until the separately delivered instrumentation
/// package is adopted by the coordinator. It never writes a file or reports a
/// completed hook installation.
public struct GameInstrumentationUnavailable: GameInstrumentationConsuming {
    public init() {}
    public func scenes(context: GameProjectContext, engine: GameEngineID,
                       gameRoot: GameRelativePath?) async throws -> [GameInstrumentationSceneChoice] {
        throw GameInstrumentationSeamError.unavailable
    }
    public func plan(context: GameProjectContext, engine: GameEngineID,
                     gameRoot: GameRelativePath?, sceneID: String?) async throws -> GameInstrumentationPlanSummary {
        throw GameInstrumentationSeamError.unavailable
    }
    public func apply(context: GameProjectContext, plan: GameInstrumentationPlanSummary,
                      expectedRevision: String) async throws -> GameInstrumentationApplyReceipt {
        throw GameInstrumentationSeamError.unavailable
    }
    public func sourceBundle(context: GameProjectContext,
                             plan: GameInstrumentationPlanSummary) async throws -> Data {
        throw GameInstrumentationSeamError.unavailable
    }
}
