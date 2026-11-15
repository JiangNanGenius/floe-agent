// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeGameCore
import FloeGameAuthoring
import FloeGameInstrumentation
import FloeGameWorkspaceHost
import FloeGameAppIntegration

/// Concrete adapter over the separately delivered `FloeGameInstrumentation`
/// actor. It reuses the live project session's repository/contexts; it never
/// writes a second tree or invents a plan. Apply re-plans and checks the
/// previewed plan ID so a stale preview cannot silently install different
/// files.
struct GameInstrumentationAdapter: GameInstrumentationConsuming {
    let registry: GameWorkspaceRegistry

    private func instrumenter(context: GameProjectContext) async throws
        -> GameDeveloperProjectInstrumenter {
        let pair = try await MainActor.run { () throws -> (FileGameProjectRepository, ExistingWorkspaceGameContexts) in
            guard let session = registry.session(projectID: context.projectID,
                                                 owner: context.owner) else {
                throw FloeError.validationFailed("Open this game project before planning development hooks")
            }
            return (session.project.repository, session.project.contexts)
        }
        return try GameDeveloperProjectInstrumenter(repository: pair.0, contexts: pair.1)
    }

    func scenes(context: GameProjectContext, engine: GameEngineID,
                gameRoot: GameRelativePath?) async throws -> [GameInstrumentationSceneChoice] {
        let values = try await instrumenter(context: context)
            .scenes(context: context, engine: engine, gameRoot: gameRoot)
        return values.map {
            .init(id: $0.id, path: $0.path.value, name: $0.name,
                  isStartScene: $0.isStartScene)
        }
    }

    func plan(context: GameProjectContext, engine: GameEngineID,
              gameRoot: GameRelativePath?, sceneID: String?) async throws -> GameInstrumentationPlanSummary {
        let value = try await instrumenter(context: context).plan(context: context,
            engine: engine, gameRoot: gameRoot, scene: sceneID)
        let supports = value.descriptor.expectedSupports
        var capabilities: [String] = []
        if supports.liveState { capabilities.append("liveState") }
        if supports.pause { capabilities.append("pause") }
        if supports.resume { capabilities.append("resume") }
        if supports.speed { capabilities.append("speed") }
        if supports.fields { capabilities.append("fields") }
        if supports.actions { capabilities.append("actions") }
        let scene = value.scene.map {
            GameInstrumentationSceneChoice(id: $0.id, path: $0.path.value,
                name: $0.name, isStartScene: $0.isStartScene)
        }
        let scenes: [GameInstrumentationSceneChoice]
        if engine == .cocosCreator {
            scenes = try await self.scenes(context: context, engine: engine, gameRoot: gameRoot)
        } else {
            scenes = []
        }
        return .init(planID: value.planID, engine: value.engine,
            gameRoot: value.gameRootPath, catalogVersion: value.catalogVersion,
            changedPaths: value.changedFiles.map(\.value),
            unchangedPaths: value.unchangedFiles.map(\.value),
            requiresRebuild: value.requiresRebuild,
            dormancyGated: value.dormancy.gated,
            scene: scene, scenes: scenes,
            exportHandling: value.exportHandling == .notApplicable ? nil : value.exportHandling.rawValue,
            capabilities: capabilities,
            diagnostics: value.diagnostics.map { $0.message })
    }

    func apply(context: GameProjectContext, plan: GameInstrumentationPlanSummary,
               expectedRevision: String) async throws -> GameInstrumentationApplyReceipt {
        guard plan.dormancyGated else { throw GameInstrumentationSeamError.dormancyUnverified }
        let root = try plan.gameRoot.isEmpty ? nil : GameRelativePath(plan.gameRoot)
        let builder = try await instrumenter(context: context)
        let accepted = try await builder.plan(context: context,
            engine: plan.engine, gameRoot: root, scene: plan.scene?.id)
        guard accepted.planID == plan.planID, accepted.context.savedRevision == expectedRevision else {
            throw GameInstrumentationSeamError.staleContext
        }
        let receipt = try await builder.apply(accepted)
        return .init(projectID: receipt.project.projectID,
            previousRevision: receipt.previousRevision, revision: receipt.revision,
            changedPaths: receipt.changedFiles.map(\.value),
            unchangedPaths: receipt.unchangedFiles.map(\.value),
            sourceBundleManifestSHA256: nil,
            requiresRebuild: accepted.requiresRebuild)
    }

    func sourceBundle(context: GameProjectContext,
                      plan: GameInstrumentationPlanSummary) async throws -> Data {
        let root = try plan.gameRoot.isEmpty ? nil : GameRelativePath(plan.gameRoot)
        let builder = try await instrumenter(context: context)
        let accepted = try await builder.plan(context: context,
            engine: plan.engine, gameRoot: root, scene: plan.scene?.id)
        guard accepted.planID == plan.planID else { throw GameInstrumentationSeamError.staleContext }
        let bundle = try await builder.bundleSourceFiles(accepted)
        struct Manifest: Encodable {
            let engine: GameEngineID
            let license: String
            let sourceRevision: String
            let manifestSHA256: String
            let aggregateSHA256: String
            let files: [String]
        }
        return try JSONEncoder().encode(Manifest(engine: bundle.engine,
            license: bundle.licenseIdentifier, sourceRevision: bundle.sourceRevision,
            manifestSHA256: bundle.manifestSHA256, aggregateSHA256: bundle.aggregateSHA256,
            files: bundle.files.map(\.path)))
    }
}
#endif
