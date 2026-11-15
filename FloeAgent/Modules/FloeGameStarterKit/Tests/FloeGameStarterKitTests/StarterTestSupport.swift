// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameAuthoring
import FloeGameStarterKit

actor StarterTestHost: GameAuthoringContextHost {
    let repository: FileGameProjectRepository
    let directory: URL
    private var active: [UUID: GameProjectContext] = [:]

    init(repository: FileGameProjectRepository, directory: URL) {
        self.repository = repository
        self.directory = directory
    }

    func set(_ context: GameProjectContext) {
        active[context.projectID] = context
    }

    func makeContext(projectID: UUID, owner: GameProjectOwner,
                     environmentID: String = "starter-test") async throws -> GameProjectContext {
        let project = try await repository.open(projectID, owner: owner)
        let target = directory.appendingPathComponent("Materialized")
            .appendingPathComponent(projectID.uuidString)
            .appendingPathComponent(project.revision)
        if !FileManager.default.fileExists(atPath: target.path) {
            _ = try await repository.export(projectID, owner: owner,
                                            expectedRevision: project.revision, to: target)
        }
        let context = try GameProjectContext(projectID: projectID, owner: owner,
                                             rootURL: target, savedRevision: project.revision,
                                             environmentID: environmentID)
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
        guard project.projectID == previous.projectID, project.owner == previous.owner else {
            throw GameProjectError.invalidContext
        }
        let target = directory.appendingPathComponent("Materialized")
            .appendingPathComponent(project.projectID.uuidString)
            .appendingPathComponent(project.revision)
        if !FileManager.default.fileExists(atPath: target.path) {
            _ = try await repository.export(project.projectID, owner: project.owner,
                                            expectedRevision: project.revision, to: target)
        }
        let context = try GameProjectContext(projectID: project.projectID, owner: project.owner,
                                             rootURL: target, savedRevision: project.revision,
                                             environmentID: previous.environmentID)
        active[project.projectID] = context
        return context
    }
}

struct StarterTestWorkspace: Sendable {
    let root: URL
    let repository: FileGameProjectRepository
    let host: StarterTestHost
    let catalog: GameStarterCatalog
    let scaffolder: GameStarterScaffolder
    let projectID: UUID
    let owner: GameProjectOwner

    init(resources: GameStarterResources = .init(),
         beforeImport: (@Sendable () throws -> Void)? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeStarterTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileGameProjectRepository(
            directory: root.appendingPathComponent("Repository"))
        let host = StarterTestHost(repository: repository, directory: root)
        let catalog = try GameStarterCatalog.bundled()
        let projectID = UUID()
        let owner = GameProjectOwner.space(recordID: projectID)
        let scaffolder = GameStarterScaffolder(
            repository: repository, contexts: host, catalog: catalog,
            resources: resources, beforeImport: beforeImport)
        self.root = root; self.repository = repository; self.host = host
        self.catalog = catalog; self.scaffolder = scaffolder
        self.projectID = projectID; self.owner = owner
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func create(title: String, engine: GameEngineID) async throws -> GameStoredProject {
        try await scaffolder.createBlankProject(projectID: projectID, owner: owner,
                                                title: title, engine: engine)
    }

    func context(_ environmentID: String = "starter-test") async throws -> GameProjectContext {
        try await host.makeContext(projectID: projectID, owner: owner,
                                   environmentID: environmentID)
    }

    func seed(engine: GameEngineID, title: String = "QA Starter",
              resources: GameStarterResources? = nil) async throws -> GameStarterInitialization {
        _ = try await create(title: title, engine: engine)
        let context = try await context()
        let scaffolder = resources.map { value in
            GameStarterScaffolder(repository: repository, contexts: host, catalog: catalog,
                                  resources: value)
        } ?? self.scaffolder
        return try await scaffolder.initializeStarter(context: context, engine: engine,
                                                      title: title)
    }

    func read(_ initialization: GameStarterInitialization, _ path: String) async throws -> Data {
        try await repository.read(initialization.project.projectID,
                                  owner: initialization.project.owner,
                                  revision: initialization.project.revision,
                                  path: GameRelativePath(path))
    }

    func paths(_ initialization: GameStarterInitialization) -> [String] {
        initialization.files.map(\.path.value)
    }
}

extension XCTestCase {
    func withWorkspace(resources: GameStarterResources = .init(),
                       beforeImport: (@Sendable () throws -> Void)? = nil,
                       _ body: (StarterTestWorkspace) async throws -> Void) async throws {
        let workspace = try StarterTestWorkspace(resources: resources, beforeImport: beforeImport)
        defer { workspace.cleanup() }
        try await body(workspace)
    }
}

func runtimePackRootFromEnvironment() -> URL? {
    if let value = ProcessInfo.processInfo.environment["FLOE_STARTER_TEST_RESOURCES"],
       !value.isEmpty {
        return URL(fileURLWithPath: value, isDirectory: true)
    }
    let candidate = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../Artifacts/game-predevelopment-expanded/authoring-starters/resource-packs")
        .standardizedFileURL
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}
