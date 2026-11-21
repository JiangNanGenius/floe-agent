// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameAuthoring

/// Seeds one explicitly created EMPTY owned project from the unified catalog.
///
/// The service never imports an external tree, never auto-seeds an import and
/// never mutates a non-empty project. The normal product flow is:
/// create blank owned project -> choose/accept engine -> initialize starter,
/// or create blank owned project -> import a whole folder/archive.
public actor GameStarterScaffolder {
    nonisolated public let repository: FileGameProjectRepository
    nonisolated public let catalog: GameStarterCatalog
    nonisolated public let resources: GameStarterResources
    nonisolated public let limits: GameStarterLimits
    private let contexts: any GameAuthoringContextHost
    private let beforeImport: (@Sendable () throws -> Void)?
    private let workRoot: URL
    private var leases: Set<UUID> = []

    public init(repository: FileGameProjectRepository,
                contexts: any GameAuthoringContextHost,
                catalog: GameStarterCatalog,
                resources: GameStarterResources = .init(),
                limits: GameStarterLimits = .standard,
                workRoot: URL = FileManager.default.temporaryDirectory,
                beforeImport: (@Sendable () throws -> Void)? = nil) {
        self.repository = repository
        self.contexts = contexts
        self.catalog = catalog
        self.resources = resources
        self.limits = limits
        self.workRoot = workRoot
        self.beforeImport = beforeImport
    }

    /// Creates a real empty project through the existing repository. Supplying
    /// the engine here lets the repository record it; an empty project created
    /// before choosing an engine remains valid and is recognized afterward from
    /// the deterministic `floe-game.json` written by the starter.
    public func createBlankProject(projectID: UUID, owner: GameProjectOwner,
                                   title: String, engine: GameEngineID? = nil) async throws -> GameStoredProject {
        try GameStarterTitle.validate(title)
        if let engine {
            guard !engine.isImportOnly else { throw GameStarterError.unsupportedEngine(engine) }
            _ = try catalog.descriptor(for: engine)
        }
        return try await repository.createProject(projectID: projectID, owner: owner,
                                                  title: title, engine: engine)
    }

    /// Seeds a template only into the exact empty revision the host resolved.
    /// A non-empty project, stale revision, changed owner/environment/root or a
    /// concurrent initialization is rejected without touching the original.
    public func initializeStarter(context: GameProjectContext, engine: GameEngineID,
                                  title: String? = nil) async throws -> GameStarterInitialization {
        guard !Task.isCancelled else { throw GameStarterError.cancelled }
        guard leases.insert(context.projectID).inserted else { throw GameStarterError.busy }
        defer { leases.remove(context.projectID) }

        let descriptor = try catalog.descriptor(for: engine)
        let current: GameProjectContext
        do {
            current = try await contexts.currentContext(for: context)
            try context.validate(current: current)
        } catch is GameProjectError {
            throw GameStarterError.contextChanged
        }
        let project: GameStoredProject
        do {
            project = try await repository.open(context.projectID, owner: context.owner)
        } catch GameProjectError.ownershipMismatch {
            throw GameStarterError.wrongOwner
        } catch let error as GameProjectError {
            throw GameStarterError.invalidProjectState(String(describing: error))
        }
        guard project.projectID == context.projectID, project.owner == context.owner,
              current.projectID == context.projectID, current.owner == context.owner,
              current.environmentID == context.environmentID,
              project.revision == context.savedRevision,
              current.savedRevision == context.savedRevision else {
            throw GameStarterError.staleRevision(expected: context.savedRevision,
                                                 actual: project.revision)
        }
        if let recorded = project.engine, recorded != engine {
            throw GameStarterError.engineMismatch(expected: engine, actual: recorded)
        }
        guard project.files.isEmpty, project.directories.isEmpty else {
            throw GameStarterError.nonEmptyProject
        }

        let resolvedTitle = title ?? project.title
        try GameStarterTitle.validate(resolvedTitle)
        let stage = workRoot.appendingPathComponent("floe-starter-" + UUID().uuidString,
                                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let materializer = GameStarterMaterializer(catalog: catalog, resources: resources,
                                                   limits: limits)
        do {
            try materializer.materialize(descriptor: descriptor, title: resolvedTitle, stage: stage)
        } catch let error as GameStarterError {
            throw error
        } catch {
            throw GameStarterError.invalidTemplate(String(describing: error))
        }
        let report = try GameStarterTreePolicy.validate(root: stage, limits: limits)
        try beforeImport?()
        guard !Task.isCancelled else { throw GameStarterError.cancelled }

        let imported: GameStoredProject
        do {
            imported = try await repository.importContents(
                from: stage, into: context.projectID, owner: context.owner,
                expectedRevision: context.savedRevision, replaceExisting: false)
        } catch let error as GameProjectError {
            switch error {
            case .importDestinationNotEmpty: throw GameStarterError.nonEmptyProject
            case .contextChanged: throw GameStarterError.contextChanged
            case .ownershipMismatch: throw GameStarterError.wrongOwner
            case .conflict(let expected, let actual):
                throw GameStarterError.staleRevision(expected: expected, actual: actual)
            case .limitExceeded(let detail): throw GameStarterError.limitExceeded(detail)
            case .unsafePath(let path): throw GameStarterError.unsafePath(path)
            case .invalidRelativePath, .invalidManifest(_), .invalidEdit, .duplicateAdapter(_):
                throw GameStarterError.invalidTemplate(String(describing: error))
            default: throw GameStarterError.io(String(describing: error))
            }
        } catch is CancellationError {
            throw GameStarterError.cancelled
        }

        let revised: GameProjectContext
        do {
            revised = try await contexts.contextAfterCommit(imported, previous: context)
        } catch {
            throw GameStarterError.contextChanged
        }
        guard revised.projectID == context.projectID, revised.owner == context.owner,
              revised.environmentID == context.environmentID,
              revised.savedRevision == imported.revision,
              imported.projectID == context.projectID,
              imported.owner == context.owner else {
            throw GameStarterError.contextChanged
        }
        let files = imported.files.sorted { $0.path.value < $1.path.value }
        return .init(project: imported, context: revised, descriptor: descriptor,
                     title: resolvedTitle, files: files,
                     manifestSHA256: GameStarterTreeDigest.sha256(files: files),
                     stageFileCount: report.fileCount, stageByteCount: report.byteCount)
    }
}
