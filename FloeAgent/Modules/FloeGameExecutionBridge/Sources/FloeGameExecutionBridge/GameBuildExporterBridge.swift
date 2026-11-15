// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameBuildKit
import FloeGameCore
import FloeGameGDevelopKit
import FloeGameNarrativeKit
import FloeGamePortableKit

public struct GameBuildExporterConfiguration: Sendable {
    public let shell: any GameShellRunning
    public let shellContext: GameShellContextProvider
    public let narrativeResources: URL?
    public let gdevelopSDKRoot: URL?
    public let gdevelopExportScript: URL?
    public let portableResources: [GameEngineID: GamePortablePreparedResources]
    public let renpySDK: URL?
    public let licensedDeployment: (any GameLicensedDeploymentRunning)?
    public let limits: GameExecutionLimits

    public init(shell: any GameShellRunning, shellContext: @escaping GameShellContextProvider,
                narrativeResources: URL?,
                gdevelopSDKRoot: URL?, gdevelopExportScript: URL?,
                portableResources: [GameEngineID: GamePortablePreparedResources],
                renpySDK: URL? = nil,
                licensedDeployment: (any GameLicensedDeploymentRunning)? = nil,
                limits: GameExecutionLimits = .default) {
        self.shell = shell
        self.shellContext = shellContext
        self.narrativeResources = narrativeResources
        self.gdevelopSDKRoot = gdevelopSDKRoot
        self.gdevelopExportScript = gdevelopExportScript
        self.portableResources = portableResources
        self.renpySDK = renpySDK
        self.licensedDeployment = licensedDeployment
        self.limits = limits
    }
}

/// `GameBuildExporterPort` over the existing narrative/GDevelop/portable
/// components. It creates no engine and no second build system.
public actor GameBuildExporterBridge: GameBuildExporterPort {
    private let configuration: GameBuildExporterConfiguration
    private let portableBridge: GamePortableBuildBridge

    public init(configuration: GameBuildExporterConfiguration) {
        self.configuration = configuration
        self.portableBridge = GamePortableBuildBridge(
            configuration: .init(shell: configuration.shell,
                                 shellContext: configuration.shellContext,
                                 limits: configuration.limits))
    }

    public func export(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult {
        try Task.checkCancellation()
        do {
            try request.validateSelectionLayout()
        } catch let error as GameBuildSelectionError {
            throw GameExecutionError.selectionInvalid(String(describing: error))
        }
        switch request.engine {
        case .ink:
            return try await exportNarrative(request) { project, target, resources in
                try GameInkAdapter.buildArtifact(projectAt: project, to: target, resources: resources)
            }
        case .twine:
            return try await exportNarrative(request) { project, target, resources in
                try GameTwineAdapter.buildArtifact(projectAt: project, to: target, resources: resources)
            }
        case .wasm4:
            return try await exportNarrative(request) { project, target, resources in
                try GameWasm4Adapter.buildArtifact(projectAt: project, to: target, resources: resources)
            }
        case .tic80:
            return try await exportNarrative(request) { project, target, resources in
                try GameTIC80Adapter.buildArtifact(projectAt: project, to: target, resources: resources)
            }
        case .microStudio:
            return try await exportNarrative(request) { project, target, resources in
                try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: target, resources: resources)
            }
        case .gdevelop:
            return try await exportGDevelop(request, context: try await configuration.shellContext())
        case .rpgMakerMV:
            return try await exportMV(request)
        case .love, .renpy:
            return try await exportPortable(request)
        case .rpgMakerMZ:
            guard let tool = configuration.licensedDeployment else {
                throw GameExecutionError.prerequisite(
                    "RPG Maker MZ Web export needs a user-supplied licensed deployment tool; the host exporter does not fabricate one.")
            }
            _ = try await tool.run(.init(
                engine: .rpgMakerMZ, sourceRoot: request.sourceRoot,
                outputURL: request.outputURL,
                entry: try GameRelativePath(request.entryPoint ?? "index.html"),
                engineVersion: request.engineVersion, revision: request.revision))
            return try await verify(request, producer: "licensed-rpg-maker-mz")
        default:
            throw GameExecutionError.unsupportedRoute(
                "\(request.engine.rawValue) has no host exporter in this package; use its CI or editor route.")
        }
    }

    private typealias NarrativeBuilder = (_ project: URL, _ target: URL, _ resources: URL) throws -> Void

    private func exportNarrative(_ request: GameBuildExporterRequest,
                                 _ builder: NarrativeBuilder) async throws -> GameBuildExporterResult {
        guard let resources = configuration.narrativeResources else {
            throw GameExecutionError.prerequisite(
                "Prepared narrative runtime resources are required for \(request.engine.rawValue).")
        }
        do {
            try builder(request.sourceRoot, request.outputURL, resources)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameExecutionError.commandFailed(
                "\(request.engine.rawValue) exporter failed: \(error)")
        }
        return try await verify(request, producer: "FloeGameNarrativeKit")
    }

    private func exportGDevelop(_ request: GameBuildExporterRequest,
                                context: GameShellContext) async throws -> GameBuildExporterResult {
        guard let sdkRoot = configuration.gdevelopSDKRoot,
              let script = configuration.gdevelopExportScript else {
            throw GameExecutionError.prerequisite(
                "GDevelop host export requires the pinned 5.6.287 SDK and the reviewed export script; otherwise use the gdevelop CI target.")
        }
        _ = try GameGDevelopSDKVerifier.verify(extractedRoot: sdkRoot, platform: .linuxX86_64)
        let projectPath = try gdevelopProjectPath(in: request.sourceRoot)
        let stage = try makeStage(prefix: "gdevelop-export", context: context)
        defer { try? GameWorkspaceTree.removeOwnedDirectory(stage) }
        let source = stage.appendingPathComponent("source", isDirectory: true)
        let output = stage.appendingPathComponent("out", isDirectory: true)
        let sdk = stage.appendingPathComponent("sdk", isDirectory: true)
        let scriptStage = stage.appendingPathComponent("gdevelop-export.py", isDirectory: false)
        try GameWorkspaceTree.copyTree(from: request.sourceRoot, to: source, limits: configuration.limits)
        try GameWorkspaceTree.copyTree(from: sdkRoot, to: sdk, limits: configuration.limits)
        try FileManager.default.copyItem(at: script, to: scriptStage)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let stagedContext = try GameProjectContext(
            projectID: request.projectID, owner: request.owner,
            rootURL: source, savedRevision: request.revision,
            environmentID: context.environmentID)
        let plan = try GameGDevelopExportPlanner.plan(
            source: stagedContext, projectPath: projectPath, sdkRoot: sdk,
            workspace: stage, output: output, platform: .linuxX86_64,
            exportScriptURL: scriptStage)
        let relativeWorkspace = try relativePath(stage, context: context)
        for command in plan.commands {
            try Task.checkCancellation()
            let arguments = command.arguments.map {
                guestPath(appValue: $0, stage: stage, context: context)
            }
            let result = try await configuration.shell.run(
                .init(executable: command.executable, arguments: arguments, cwd: relativeWorkspace),
                context: context)
            guard result.exitCode == 0 else {
                throw GameExecutionError.commandFailed(
                    "GDevelop export exited \(result.exitCode): \(String(decoding: result.stderr.suffix(2_048), as: UTF8.self))")
            }
        }
        try Task.checkCancellation()
        try GameWorkspaceTree.publishContents(
            of: output, to: request.outputURL,
            expectedEntry: try GameRelativePath(request.entryPoint ?? "index.html"),
            limits: configuration.limits)
        // Stamp the reviewed dormant bridge into this private playable copy.
        // The official project JSON and every other exported byte are kept;
        // a shape without the official GDJS entry fails instead of degrading.
        _ = try GameGDevelopExportBridge.decorate(directory: request.outputURL)
        return .init(engine: .gdevelop, outputURL: request.outputURL,
                     entry: request.entryPoint ?? "index.html",
                     producerID: "FloeGameGDevelopKit.GameGDevelopExportRunner")
    }

    private func exportMV(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult {
        let manifest = try GameWorkspaceTree.manifest(rootURL: request.sourceRoot, limits: configuration.limits)
        let descriptor = try GamePortableProjectDescriptor(
            rootURL: request.sourceRoot, projectID: request.projectID, owner: request.owner,
            revision: request.revision, context: nil, files: manifest.files.map(\.path))
        let output: GamePortableBuildOutput
        do {
            output = try GamePortableMVAssembler.assemble(
                project: descriptor, resources: configuration.portableResources[.rpgMakerMV],
                to: request.outputURL)
        } catch {
            throw GameExecutionError.commandFailed("RPG Maker MV assembly failed: \(error)")
        }
        return .init(engine: .rpgMakerMV, outputURL: output.directory,
                     entry: output.entry.value, producerID: "FloeGamePortableKit.GamePortableMVAssembler")
    }

    private func exportPortable(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult {
        let adapter: any GamePortableAdapter = request.engine == .love
            ? GamePortableLoveAdapter() : GamePortableRenPyAdapter()
        let manifest = try GameWorkspaceTree.manifest(rootURL: request.sourceRoot, limits: configuration.limits)
        let descriptor = try GamePortableProjectDescriptor(
            rootURL: request.sourceRoot, projectID: request.projectID, owner: request.owner,
            revision: request.revision, context: nil, files: manifest.files.map(\.path))
        let profile = try adapter.inspect(descriptor)
        guard profile.readiness != .webReady else {
            // A ready Web export is sealed by the coordinator's static path; a
            // host exporter must not re-run an engine on it.
            throw GameExecutionError.unsupportedRoute(
                "\(request.engine.rawValue) source is already a Web export; use the static run/build path.")
        }
        let resources = configuration.portableResources[request.engine]
        guard request.engine == .renpy || resources != nil else {
            throw GameExecutionError.prerequisite(
                "Prepared \(request.engine.rawValue) resources are required.")
        }
        let plan = try adapter.plan(
            for: descriptor, outputURL: request.outputURL, resources: resources,
            sdkURL: request.engine == .renpy ? configuration.renpySDK : nil)
        let buildRequest = try GamePortableBuildRequest(
            project: descriptor, outputURL: request.outputURL, resources: resources,
            sdkURL: request.engine == .renpy ? configuration.renpySDK : nil,
            title: request.engine.rawValue, memoryBytes: 33_554_432)
        let output = try await portableBridge.execute(plan, request: buildRequest)
        return .init(engine: request.engine, outputURL: output.directory,
                     entry: output.entry.value, producerID: "FloeGamePortableKit")
    }

    private func verify(_ request: GameBuildExporterRequest,
                        producer: String) async throws -> GameBuildExporterResult {
        let entry = request.entryPoint ?? "index.html"
        guard FileManager.default.fileExists(
            atPath: request.outputURL.appendingPathComponent(entry).path) else {
            throw GameExecutionError.artifactInvalid("exporter did not produce \(entry)")
        }
        return .init(engine: request.engine, outputURL: request.outputURL,
                     entry: entry, producerID: producer)
    }

    private func makeStage(prefix: String, context: GameShellContext) throws -> URL {
        let stage = context.workspaceRoot
            .appendingPathComponent(".floe-\(prefix)-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: stage.path) else {
            throw GameExecutionError.invalidConfiguration("staging identity collision")
        }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        return stage
    }

    private func relativePath(_ url: URL, context: GameShellContext) throws -> String {
        let base = context.workspaceRoot
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else {
            throw GameExecutionError.outputEscaped("staging path is outside the workspace")
        }
        return String(path.dropFirst(base.count))
    }

    private func guestPath(appValue: String, stage: URL, context: GameShellContext) -> String {
        let stagePath = stage.standardizedFileURL.path
        guard appValue.hasPrefix(stagePath) else { return appValue }
        let relative = String(appValue.dropFirst(stagePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = context.guestWorkspaceRoot + "/"
            + ((try? relativePath(stage, context: context)) ?? "")
        return relative.isEmpty ? base : base + "/" + relative
    }

    private func gdevelopProjectPath(in source: URL) throws -> GameRelativePath {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        let candidates = ["game.json"] + names.filter { $0.lowercased().hasSuffix(".json") }.sorted()
        for name in candidates {
            let url = source.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= 262_144,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["gdVersion"] != nil, object["layouts"] != nil else { continue }
            return try GameRelativePath(name)
        }
        throw GameExecutionError.prerequisite("No standard GDevelop project was found.")
    }
}
