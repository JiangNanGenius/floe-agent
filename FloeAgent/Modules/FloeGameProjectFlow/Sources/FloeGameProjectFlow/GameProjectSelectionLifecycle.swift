// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameAuthoring
import FloeGameCore
import FloeGameStarterKit

public struct GameProjectSeedResult: Sendable {
    public let initialization: GameStarterInitialization
    public let snapshot: GameProjectSelectionSnapshot

    init(initialization: GameStarterInitialization,
         snapshot: GameProjectSelectionSnapshot) {
        self.initialization = initialization
        self.snapshot = snapshot
    }
}

public struct GameProjectImportResult: Sendable {
    public let project: GameStoredProject
    public let context: GameProjectContext
    public let snapshot: GameProjectSelectionSnapshot

    init(project: GameStoredProject, context: GameProjectContext,
         snapshot: GameProjectSelectionSnapshot) {
        self.project = project
        self.context = context
        self.snapshot = snapshot
    }
}

public struct GameProjectForkTarget: Equatable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let title: String
    public let engine: GameEngineID

    public init(projectID: UUID, owner: GameProjectOwner,
                title: String, engine: GameEngineID) throws {
        guard GameProjectSelectionText.validIdentifier(title) else {
            throw GameProjectFlowError.invalidContext
        }
        if case .space(let recordID) = owner, recordID != projectID {
            throw GameProjectFlowError.forkIdentityInvalid
        }
        self.projectID = projectID
        self.owner = owner
        self.title = title
        self.engine = engine
    }
}

public enum GameProjectEngineChangeConversion: String, Codable, Equatable, Sendable {
    /// No lossy automatic translation is performed. The copied source stays
    /// byte-identical; conversion/recreation is an explicit user/host action.
    case explicitManualConversionRequired
}

public enum GameProjectForkStep: String, Codable, Equatable, Sendable {
    case bindNewWorkspace
    case reviewCopiedFiles
    case convertOrRecreateWithTargetEngine
    case keepSourceProjectAsOriginal
    case refreshSelectionAfterConversion
}

public struct GameProjectForkPreparation: Equatable, Sendable {
    public let sourceProjectID: UUID
    public let sourceRevision: String
    public let sourceEngine: GameEngineID?
    public let targetEngine: GameEngineID
    public let newProject: GameStoredProject
    public let owner: GameProjectOwner
    public let copiedFileCount: Int
    public let copiedDirectoryCount: Int
    public let conversion: GameProjectEngineChangeConversion
    public let steps: [GameProjectForkStep]

    init(sourceProjectID: UUID, sourceRevision: String, sourceEngine: GameEngineID?,
         targetEngine: GameEngineID, newProject: GameStoredProject,
         owner: GameProjectOwner, copiedFileCount: Int, copiedDirectoryCount: Int,
         conversion: GameProjectEngineChangeConversion, steps: [GameProjectForkStep]) {
        self.sourceProjectID = sourceProjectID
        self.sourceRevision = sourceRevision
        self.sourceEngine = sourceEngine
        self.targetEngine = targetEngine
        self.newProject = newProject
        self.owner = owner
        self.copiedFileCount = copiedFileCount
        self.copiedDirectoryCount = copiedDirectoryCount
        self.conversion = conversion
        self.steps = steps
    }
}

extension GameProjectSelectionCoordinator {
    /// Creates the real empty owned project through the bundled starter.
    /// Import must happen later through `importProject`, never by seeding here.
    public func createEmptyProject(projectID: UUID, owner: GameProjectOwner,
                                   title: String, engine: GameEngineID? = nil)
        async throws -> GameStoredProject {
        try Task.checkCancellation()
        do {
            return try await scaffolder.createBlankProject(
                projectID: projectID, owner: owner, title: title, engine: engine)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameStarterError {
            throw GameProjectFlowError.starter(error)
        } catch let error as GameProjectError {
            throw GameProjectSelectionValidation.mapProject(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
    }

    /// Seeds one actual bundled starter into an already-created empty project.
    /// The engine choice is explicit; the resulting files are freshly
    /// recognized before a selection is persisted.
    public func createEngineProject(emptyProject: GameStoredProject,
                                    context: GameProjectContext,
                                    engine: GameEngineID,
                                    title: String? = nil) async throws
        -> GameProjectSeedResult {
        try Task.checkCancellation()
        try GameProjectSelectionValidation.project(emptyProject, context: context)
        guard emptyProject.files.isEmpty, emptyProject.directories.isEmpty else {
            throw GameProjectFlowError.nonEmptyProject
        }
        do {
            _ = try catalog.descriptor(for: engine)
        } catch {
            throw GameProjectFlowError.unknownEngine(engine)
        }
        let key = try selectionKey(context)
        let token = beginWrite(key)
        do {
            let initialization = try await scaffolder.initializeStarter(
                context: context, engine: engine, title: title)
            try GameProjectSelectionValidation.handoff(
                initialization.context, previous: context, project: initialization.project)
            // The user explicitly chose this engine and the scaffolder wrote it
            // at the project root. This also resolves metadata-only nested
            // roots (for example a bundled package/project.json) without
            // silently choosing among real imported games.
            let resolution = try await resolver().resolve(
                project: initialization.project, context: initialization.context,
                loadedRecord: nil,
                intent: GameProjectSelectionIntent(root: nil, engine: engine))
            try requireWrite(key, token)
            try Task.checkCancellation()
            let snapshot = try await applyPersistence(
                resolution, context: initialization.context, key: key,
                observedGeneration: token, mandatory: false)
            return .init(initialization: initialization, snapshot: snapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameProjectFlowError {
            throw error
        } catch let error as GameStarterError {
            throw GameProjectFlowError.starter(error)
        } catch let error as GameProjectError {
            throw GameProjectSelectionValidation.mapProject(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
    }

    /// Imports the whole already-unpacked tree into the empty owned project.
    /// It never seeds a starter and never overwrites non-empty content.
    public func importProject(from source: URL,
                              emptyProject: GameStoredProject,
                              context: GameProjectContext) async throws
        -> GameProjectImportResult {
        try Task.checkCancellation()
        try GameProjectSelectionValidation.project(emptyProject, context: context)
        guard emptyProject.files.isEmpty, emptyProject.directories.isEmpty else {
            throw GameProjectFlowError.nonEmptyProject
        }
        let key = try selectionKey(context)
        let token = beginWrite(key)

        let imported: GameStoredProject
        do {
            imported = try await repository.importContents(
                from: source, into: context.projectID, owner: context.owner,
                expectedRevision: context.savedRevision, replaceExisting: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameProjectError {
            throw GameProjectSelectionValidation.mapProject(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }

        let revised: GameProjectContext
        do {
            revised = try await contexts.contextAfterCommit(imported, previous: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameProjectFlowError.contextHandoff(
                GameProjectSelectionText.bounded(error))
        }
        try GameProjectSelectionValidation.handoff(revised, previous: context,
                                                   project: imported)

        let resolution = try await resolver().resolve(
            project: imported, context: revised, loadedRecord: nil, intent: nil)
        try requireWrite(key, token)
        try Task.checkCancellation()
        let snapshot = try await applyPersistence(
            resolution, context: revised, key: key,
            observedGeneration: token, mandatory: false)
        return .init(project: imported, context: revised, snapshot: snapshot)
    }

    /// Copies the complete project into a new identity for an explicit engine
    /// change. The source revision, bytes and history are retained; no engine
    /// data is translated and no selection is written for the new project.
    ///
    /// With the production working-tree adapter, the host must first bind the
    /// new project identity to an existing empty workspace/root. `repository.copy`
    /// then writes only that new target; the source live root is never touched.
    public func prepareEngineChangeFork(from project: GameStoredProject,
                                        context: GameProjectContext,
                                        to target: GameProjectForkTarget) async throws
        -> GameProjectForkPreparation {
        try Task.checkCancellation()
        try GameProjectSelectionValidation.project(project, context: context)
        guard target.projectID != project.projectID else {
            throw GameProjectFlowError.forkIdentityInvalid
        }
        do {
            _ = try catalog.descriptor(for: target.engine)
        } catch {
            throw GameProjectFlowError.unknownEngine(target.engine)
        }
        try await GameProjectSelectionValidation.currentContext(context, contexts: contexts)
        try await GameProjectSelectionValidation.currentProject(project,
                                                               repository: repository)

        let copied: GameStoredProject
        do {
            copied = try await repository.copy(
                project.projectID, owner: project.owner,
                to: target.projectID, newOwner: target.owner, title: target.title)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameProjectError {
            throw GameProjectSelectionValidation.mapProject(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
        guard copied.files == project.files,
              copied.directories == project.directories else {
            throw GameProjectFlowError.project(.corruptStorage)
        }
        let after = try await openProject(id: project.projectID, owner: project.owner)
        guard after.revision == project.revision, after.files == project.files,
              after.directories == project.directories else {
            throw GameProjectFlowError.staleProject(
                expected: project.revision, actual: after.revision)
        }
        return .init(sourceProjectID: project.projectID,
                     sourceRevision: project.revision,
                     sourceEngine: project.engine,
                     targetEngine: target.engine,
                     newProject: copied,
                     owner: target.owner,
                     copiedFileCount: copied.files.count,
                     copiedDirectoryCount: copied.directories.count,
                     conversion: .explicitManualConversionRequired,
                     steps: [.bindNewWorkspace, .reviewCopiedFiles,
                             .convertOrRecreateWithTargetEngine,
                             .keepSourceProjectAsOriginal,
                             .refreshSelectionAfterConversion])
    }
}
