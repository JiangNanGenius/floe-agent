// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameAuthoring
import FloeGameStarterKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor CLIContextHost: GameAuthoringContextHost {
    let repository: FileGameProjectRepository
    let directory: URL
    private var active: [UUID: GameProjectContext] = [:]

    init(repository: FileGameProjectRepository, directory: URL) {
        self.repository = repository
        self.directory = directory
    }

    func activate(_ context: GameProjectContext) {
        active[context.projectID] = context
    }

    func makeContext(projectID: UUID, owner: GameProjectOwner) async throws -> GameProjectContext {
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
                                             environmentID: "floe-starter-cli")
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

func emit(_ data: Data, to handle: FileHandle = .standardOutput) {
    try? handle.write(contentsOf: data)
}

func fail(_ message: String) -> Never {
    emit(Data((message + "\n").utf8), to: .standardError)
    exit(2)
}

func option(_ name: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func printJSON(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value,
                                          options: [.sortedKeys, .prettyPrinted])
    emit(data)
    emit(Data([10]))
}

@main
struct GameStarterCommand {
    static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        fail("usage: floe-game-starter <catalog|verify|create> [options]")
    }
    do {
        let catalog = try GameStarterCatalog.bundled()
        switch command {
        case "catalog":
            emit(try catalog.manifest())
            emit(Data([10]))
        case "verify":
            try catalog.verifyBundledStaticTemplates()
            for descriptor in catalog.engines { try descriptor.defaultInput.validate() }
            try printJSON([
                "result": "verified",
                "catalogVersion": catalog.catalogVersion,
                "engines": catalog.engines.count,
                "static": catalog.engines.filter { $0.templateKind == .static }.count,
                "delegated": catalog.engines.filter { $0.templateKind == .delegated }.count,
                "runtimePack": catalog.engines.filter { $0.templateKind == .runtimePack }.count,
            ])
        case "create":
            guard let engineRaw = option("--engine", arguments),
                  let engine = GameEngineID(rawValue: engineRaw) else {
                fail("missing or unknown --engine (use an exact GameEngineID raw value)")
            }
            guard let repositoryPath = option("--repository", arguments) else {
                fail("missing --repository")
            }
            guard let projectRaw = option("--project", arguments),
                  let projectID = UUID(uuidString: projectRaw) else {
                fail("missing or invalid --project UUID")
            }
            let title = option("--title", arguments) ?? "Floe Starter"
            let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            let repository = try FileGameProjectRepository(
                directory: repositoryURL.appendingPathComponent("Repository"))
            let host = CLIContextHost(repository: repository, directory: repositoryURL)
            var resources = GameStarterResources()
            if let root = option("--resources", arguments) {
                resources = .from(root: URL(fileURLWithPath: root, isDirectory: true))
            }
            let scaffolder = GameStarterScaffolder(
                repository: repository, contexts: host, catalog: catalog, resources: resources)
            let owner = GameProjectOwner.space(recordID: projectID)
            _ = try await scaffolder.createBlankProject(projectID: projectID, owner: owner,
                                                        title: title, engine: engine)
            let context = try await host.makeContext(projectID: projectID, owner: owner)
            let result = try await scaffolder.initializeStarter(
                context: context, engine: engine, title: title)
            try printJSON([
                "result": "created",
                "engine": result.engine.rawValue,
                "projectID": result.project.projectID.uuidString,
                "revision": result.project.revision,
                "title": result.title,
                "entry": result.descriptor.entry.value,
                "files": result.files.count,
                "bytes": result.files.reduce(0) { $0 + $1.bytes },
                "manifestSHA256": result.manifestSHA256,
                "contextRoot": result.context.rootURL.path,
                "repositoryEngine": result.repositoryEngine?.rawValue ?? "",
            ])
        default:
            fail("unknown command: \(command)")
        }
    } catch {
        fail("error: \(error)")
    }
    }
}
