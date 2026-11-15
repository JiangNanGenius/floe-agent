// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameAuthoring
import FloeGameRunKit
import FloeGameStarterKit
import FloeGameWebKit
@testable import FloeGameProjectFlow

actor SelectionTestContextHost: GameAuthoringContextHost, GameRunContextHost {
    let repository: FileGameProjectRepository
    let baseRoot: URL
    private var active: [UUID: GameProjectContext] = [:]
    private var applied: [UUID: String] = [:]
    private var roots: [UUID: URL] = [:]

    init(repository: FileGameProjectRepository, baseRoot: URL) throws {
        self.repository = repository
        self.baseRoot = baseRoot
        try FileManager.default.createDirectory(at: baseRoot,
                                                withIntermediateDirectories: true)
    }

    func bind(projectID: UUID, owner: GameProjectOwner,
              environmentID: String = "selection-test") async throws -> GameProjectContext {
        let project = try await repository.open(projectID, owner: owner)
        let root = roots[projectID]
            ?? baseRoot.appendingPathComponent(projectID.uuidString.lowercased(),
                                              isDirectory: true)
        roots[projectID] = root
        try await materialize(project, root: root)
        let context = try GameProjectContext(
            projectID: projectID, owner: owner, rootURL: root,
            savedRevision: project.revision, environmentID: environmentID)
        active[projectID] = context
        return context
    }

    func currentContext(for context: GameProjectContext) async throws -> GameProjectContext {
        guard let value = active[context.projectID] else {
            throw GameProjectError.contextChanged(.project)
        }
        return value
    }

    func contextAfterCommit(_ project: GameStoredProject,
                            previous: GameProjectContext) async throws -> GameProjectContext {
        guard project.projectID == previous.projectID,
              project.owner == previous.owner,
              let root = roots[project.projectID] else {
            throw GameProjectError.invalidContext
        }
        try await materialize(project, root: root)
        let context = try GameProjectContext(
            projectID: project.projectID, owner: project.owner,
            rootURL: root, savedRevision: project.revision,
            environmentID: previous.environmentID)
        active[project.projectID] = context
        return context
    }

    func contextChangingEnvironment(_ context: GameProjectContext,
                                    to environmentID: String) throws -> GameProjectContext {
        try GameProjectContext(projectID: context.projectID, owner: context.owner,
                               rootURL: context.rootURL,
                               savedRevision: context.savedRevision,
                               environmentID: environmentID)
    }

    func contextChangingRoot(_ context: GameProjectContext, to rootURL: URL) throws
        -> GameProjectContext {
        try GameProjectContext(projectID: context.projectID, owner: context.owner,
                               rootURL: rootURL,
                               savedRevision: context.savedRevision,
                               environmentID: context.environmentID)
    }

    func contextChangingOwner(_ context: GameProjectContext,
                              to owner: GameProjectOwner) throws -> GameProjectContext {
        try GameProjectContext(projectID: context.projectID, owner: owner,
                               rootURL: context.rootURL,
                               savedRevision: context.savedRevision,
                               environmentID: context.environmentID)
    }

    private func materialize(_ project: GameStoredProject, root: URL) async throws {
        if applied[project.projectID] == project.revision,
           FileManager.default.fileExists(atPath: root.path) {
            return
        }
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent,
                                                withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".selection-export-" + UUID().uuidString, isDirectory: true)
        _ = try await repository.export(project.projectID, owner: project.owner,
                                        expectedRevision: project.revision, to: temporary)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.moveItem(at: temporary, to: root)
        applied[project.projectID] = project.revision
    }
}

final class SelectionTestWorkspace: @unchecked Sendable {
    let root: URL
    let repository: FileGameProjectRepository
    let host: SelectionTestContextHost
    let catalog: GameStarterCatalog
    let scaffolder: GameStarterScaffolder
    let store: InMemoryGameProjectSelectionStore
    let coordinator: GameProjectSelectionCoordinator
    let projectID: UUID
    let owner: GameProjectOwner
    let environmentID: String

    init(catalog: GameStarterCatalog? = nil,
         resources: GameStarterResources = .init(),
         recommender: GameProjectSelectionRecommendationHandler? = nil,
         capabilityProbe: (any GameProjectSelectionCapabilityProbe)? = nil,
         beforeImport: (@Sendable () throws -> Void)? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeSelectionTest-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Staging", isDirectory: true),
            withIntermediateDirectories: true)
        let repository = try FileGameProjectRepository(
            directory: root.appendingPathComponent("Repository", isDirectory: true))
        let host = try SelectionTestContextHost(
            repository: repository,
            baseRoot: root.appendingPathComponent("Projects", isDirectory: true))
        let resolvedCatalog: GameStarterCatalog
        if let catalog = catalog {
            resolvedCatalog = catalog
        } else {
            resolvedCatalog = try GameStarterCatalog.bundled()
        }
        let scaffolder = GameStarterScaffolder(
            repository: repository, contexts: host, catalog: resolvedCatalog,
            resources: resources, workRoot: root.appendingPathComponent(
                "Staging", isDirectory: true), beforeImport: beforeImport)
        let store = InMemoryGameProjectSelectionStore()
        let projectID = UUID()
        let owner = GameProjectOwner.space(recordID: projectID)
        let environmentID = "selection-" + projectID.uuidString.lowercased()
        let coordinator = try GameProjectSelectionCoordinator(
            scaffolder: scaffolder, contexts: host, store: store,
            recommender: recommender, capabilityProbe: capabilityProbe)
        self.root = root
        self.repository = repository
        self.host = host
        self.catalog = resolvedCatalog
        self.scaffolder = scaffolder
        self.store = store
        self.projectID = projectID
        self.owner = owner
        self.environmentID = environmentID
        self.coordinator = coordinator
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func createEmpty(engine: GameEngineID? = nil,
                     projectID: UUID? = nil,
                     owner: GameProjectOwner? = nil) async throws
        -> (GameStoredProject, GameProjectContext) {
        let id = projectID ?? self.projectID
        let owner = owner ?? self.owner
        let empty = try await coordinator.createEmptyProject(
            projectID: id, owner: owner, title: "Fixture \(id.uuidString.prefix(8))",
            engine: engine)
        let context = try await host.bind(projectID: id, owner: owner,
                                          environmentID: environmentID)
        return (empty, context)
    }

    func context(projectID: UUID? = nil,
                 owner: GameProjectOwner? = nil) async throws -> GameProjectContext {
        let id = projectID ?? self.projectID
        let owner = owner ?? self.owner
        return try await host.bind(projectID: id, owner: owner,
                                   environmentID: environmentID)
    }

    func currentProject(projectID: UUID? = nil,
                        owner: GameProjectOwner? = nil) async throws -> GameStoredProject {
        try await repository.open(projectID ?? self.projectID, owner: owner ?? self.owner)
    }

    func storedRecord(context: GameProjectContext? = nil,
                      projectID: UUID? = nil,
                      owner: GameProjectOwner? = nil) async throws
        -> GameProjectSelectionRecord? {
        let resolved: GameProjectContext
        if let context = context {
            resolved = context
        } else {
            resolved = try await self.context(projectID: projectID, owner: owner)
        }
        let key = try GameProjectSelectionKey(context: resolved)
        return try await store.load(for: key)
    }

    func key(context: GameProjectContext? = nil,
             projectID: UUID? = nil,
             owner: GameProjectOwner? = nil) async throws -> GameProjectSelectionKey {
        let resolved: GameProjectContext
        if let context = context {
            resolved = context
        } else {
            resolved = try await self.context(projectID: projectID, owner: owner)
        }
        return try GameProjectSelectionKey(context: resolved)
    }

    func makeSource(_ files: [String: Data]) throws -> URL {
        let source = root.appendingPathComponent(
            "Sources/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source,
                                                withIntermediateDirectories: true)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }
        return source
    }

    func importFiles(_ files: [String: Data], engine: GameEngineID? = nil,
                     projectID: UUID? = nil, owner: GameProjectOwner? = nil)
        async throws -> GameProjectImportResult {
        let created = try await createEmpty(engine: engine, projectID: projectID,
                                            owner: owner)
        let source = try makeSource(files)
        return try await coordinator.importProject(
            from: source, emptyProject: created.0, context: created.1)
    }

    func seed(engine: GameEngineID, title: String? = nil) async throws
        -> GameProjectSeedResult {
        let created = try await createEmpty()
        return try await coordinator.createEngineProject(
            emptyProject: created.0, context: created.1, engine: engine, title: title)
    }

    func importFor(projectID: UUID, owner: GameProjectOwner,
                   files: [String: Data]) async throws
        -> (project: GameStoredProject, context: GameProjectContext) {
        _ = try await repository.createProject(
            projectID: projectID, owner: owner,
            title: "Fixture \(projectID.uuidString.prefix(8))")
        let initial = try await host.bind(projectID: projectID, owner: owner,
                                          environmentID: environmentID)
        let imported = try await repository.importContents(
            from: makeSource(files), into: projectID, owner: owner,
            expectedRevision: initial.savedRevision)
        let revised = try await host.contextAfterCommit(imported, previous: initial)
        return (imported, revised)
    }
}

extension XCTestCase {
    func withSelectionWorkspace(
        resources: GameStarterResources = .init(),
        recommender: GameProjectSelectionRecommendationHandler? = nil,
        capabilityProbe: (any GameProjectSelectionCapabilityProbe)? = nil,
        beforeImport: (@Sendable () throws -> Void)? = nil,
        _ body: (SelectionTestWorkspace) async throws -> Void
    ) async throws {
        let workspace = try SelectionTestWorkspace(
            resources: resources, recommender: recommender,
            capabilityProbe: capabilityProbe, beforeImport: beforeImport)
        defer { workspace.cleanup() }
        try await body(workspace)
    }
}
