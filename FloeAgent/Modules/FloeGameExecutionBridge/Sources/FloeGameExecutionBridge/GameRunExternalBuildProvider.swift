// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameGDevelopKit
import FloeGameRunKit

/// Host-side configuration for run-time external builds. The Main binding
/// supplies the shell and authority; this type contains no credential and no
/// environment selection of its own.
public struct GameExternalBuildConfiguration: Sendable {
    public let shell: any GameShellRunning
    public let authority: GameExecutionAuthorityProvider
    public let limits: GameExecutionLimits
    public let guestWorkspaceRoot: String
    public let godotExecutable: String
    public let gdevelopSDKRoot: URL?
    public let gdevelopExportScript: URL?
    public let licensedDeployment: (any GameLicensedDeploymentRunning)?
    public let ci: GameRunCIExecutor?
    /// Revalidates the original owner/project/environment/root/revision around
    /// a long local export or CI dispatch. Nil is a direct fixture.
    public let currentContext: GameRunLiveContextResolver?

    public init(shell: any GameShellRunning,
                authority: @escaping GameExecutionAuthorityProvider,
                limits: GameExecutionLimits = .default,
                guestWorkspaceRoot: String = "/workspace",
                godotExecutable: String = "godot",
                gdevelopSDKRoot: URL? = nil,
                gdevelopExportScript: URL? = nil,
                licensedDeployment: (any GameLicensedDeploymentRunning)? = nil,
                ci: GameRunCIExecutor? = nil,
                currentContext: GameRunLiveContextResolver? = nil) {
        self.shell = shell
        self.authority = authority
        self.limits = limits
        self.guestWorkspaceRoot = guestWorkspaceRoot
        self.godotExecutable = godotExecutable
        self.gdevelopSDKRoot = gdevelopSDKRoot
        self.gdevelopExportScript = gdevelopExportScript
        self.licensedDeployment = licensedDeployment
        self.ci = ci
        self.currentContext = currentContext
    }
}

/// `GameRunExternalBuildProviding` over the existing host shell and CI seams.
/// Local builds run in a private copy below the task workspace; CI builds
/// publish exactly the same source digest and never adopt a different run.
public actor GameRunExternalBuildProvider: GameRunExternalBuildProviding {
    private let configuration: GameExternalBuildConfiguration

    public init(configuration: GameExternalBuildConfiguration) {
        self.configuration = configuration
    }

    public func build(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        try Task.checkCancellation()
        try await validateSelection(request)
        try ensureOutputIsOutsideSource(request)
        switch request.kind {
        case .unityWebGL, .cocosWeb:
            return try await runCI(request)
        case .webBundle:
            // Project npm code is never executed on the device. The run route
            // reaches this provider only when the source is not a self-contained
            // Web tree, so use the isolated CI build or fail honestly.
            return try await runCI(request)
        case .godotWeb:
            return try await runGodot(request, shellContext: try await localShellContext(request))
        case .gdevelopWeb:
            if configuration.gdevelopSDKRoot != nil,
               configuration.gdevelopExportScript != nil {
                return try await runGDevelop(request, shellContext: try await localShellContext(request))
            }
            return try await runCI(request)
        case .rpgMakerMZWeb, .rpgMakerMVDeployment:
            return try await runLicensedDeployment(request)
        }
    }

    private func localShellContext(_ request: GameRunExternalBuildRequest) async throws -> GameShellContext {
        let authority = try await configuration.authority(request.context)
        guard request.context.environmentID == nil
                || request.context.environmentID == authority.environmentID else {
            throw GameExecutionError.prerequisite(
                "The game project's environment changed while the build was starting.")
        }
        return GameShellContext(
            workspaceRoot: request.context.rootURL,
            guestWorkspaceRoot: configuration.guestWorkspaceRoot,
            environmentID: authority.environmentID,
            conversationID: authority.conversationID,
            runID: authority.runID,
            executionBindingGeneration: authority.executionBindingGeneration)
    }

    // MARK: - Godot

    private func runGodot(_ request: GameRunExternalBuildRequest,
                          shellContext: GameShellContext) async throws -> GameRunExternalBuildOutput {
        let preset = try Self.godotWebPreset(in: request.sourceRoot)
        let stage = try makeStage(near: request.context.rootURL)
        defer { try? GameWorkspaceTree.removeOwnedDirectory(stage.root) }
        let source = stage.root.appendingPathComponent("source", isDirectory: true)
        let output = stage.root.appendingPathComponent("out", isDirectory: true)
        let copiedSource = try GameWorkspaceTree.copyTree(
            from: request.sourceRoot, to: source, limits: configuration.limits)
        try validatePrepared(request, digest: copiedSource.digest)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let relativeSource = try Self.relativePath(source, under: shellContext.workspaceRoot)
        let guestSource = shellContext.guestWorkspaceRoot + "/" + relativeSource
        let guestOutput = shellContext.guestWorkspaceRoot + "/" + (try Self.relativePath(output, under: shellContext.workspaceRoot))
        let version = try await configuration.shell.run(
            .init(executable: configuration.godotExecutable, arguments: ["--version"], cwd: relativeSource),
            context: shellContext)
        guard version.exitCode == 0 else {
            throw GameExecutionError.prerequisite(
                "The Godot editor is not available at '\(configuration.godotExecutable)'. Install a matching 4.x editor and its Web export templates, or use the reviewed CI template.")
        }
        try Task.checkCancellation()
        let result = try await configuration.shell.run(
            .init(executable: configuration.godotExecutable,
                  arguments: ["--headless", "--path", guestSource,
                              "--export-release", preset, guestOutput + "/index.html"],
                  cwd: relativeSource),
            context: shellContext)
        guard result.exitCode == 0 else {
            throw GameExecutionError.commandFailed(
                "Godot Web export exited \(result.exitCode): \(Self.tail(result.stderr))")
        }
        try Task.checkCancellation()
        try GameWorkspaceTree.publishContents(
            of: output, to: request.outputDirectory,
            expectedEntry: request.expectedEntry, limits: configuration.limits)
        try await validateSelection(request)
        return try makeOutput(request, expectedEntry: request.expectedEntry,
                              evidence: ["godot-web", "preset:\(preset)"],
                              wholeDigest: copiedSource.digest,
                              sourceTransport: "localPrepared")
    }

    private static func godotWebPreset(in source: URL) throws -> String {
        let file = source.appendingPathComponent("export_presets.cfg")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw GameExecutionError.prerequisite(
                "Godot source has no export_presets.cfg. Add a Web export preset in the Godot editor; Floe does not fabricate one.")
        }
        var names: [(name: String, platform: String)] = []
        var currentName: String?
        var currentPlatform: String?
        func flush() {
            if let currentName, let currentPlatform {
                names.append((currentName, currentPlatform))
            }
            currentName = nil; currentPlatform = nil
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[preset.") { flush(); continue }
            if line.hasPrefix("name=") {
                currentName = String(line.dropFirst("name=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if line.hasPrefix("platform=") {
                currentPlatform = String(line.dropFirst("platform=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        flush()
        guard let preset = names.first(where: { $0.platform.caseInsensitiveCompare("Web") == .orderedSame }) else {
            throw GameExecutionError.prerequisite(
                "Godot source has no Web export preset. Add a preset whose platform is Web; the source is preserved.")
        }
        return preset.name
    }

    // MARK: - GDevelop

    private func runGDevelop(_ request: GameRunExternalBuildRequest,
                             shellContext: GameShellContext) async throws -> GameRunExternalBuildOutput {
        guard let sdkRoot = configuration.gdevelopSDKRoot,
              let script = configuration.gdevelopExportScript else {
            throw GameExecutionError.prerequisite(
                "GDevelop host export requires the pinned 5.6.287 SDK and the reviewed export script.")
        }
        // Verify the extracted SDK receipt before copying a byte into the task
        // workspace. A receipt mismatch is a hard failure, not a warning.
        _ = try GameGDevelopSDKVerifier.verify(extractedRoot: sdkRoot, platform: .linuxX86_64)
        let projectPath = try Self.gdevelopProjectPath(in: request.sourceRoot)
        let stage = try makeStage(near: request.context.rootURL)
        defer { try? GameWorkspaceTree.removeOwnedDirectory(stage.root) }
        let source = stage.root.appendingPathComponent("source", isDirectory: true)
        let output = stage.root.appendingPathComponent("out", isDirectory: true)
        let sdk = stage.root.appendingPathComponent("gdevelop-sdk", isDirectory: true)
        let scriptStage = stage.root.appendingPathComponent("gdevelop-export.py", isDirectory: false)
        let copiedSource = try GameWorkspaceTree.copyTree(
            from: request.sourceRoot, to: source, limits: configuration.limits)
        try validatePrepared(request, digest: copiedSource.digest)
        try GameWorkspaceTree.copyTree(from: sdkRoot, to: sdk, limits: configuration.limits)
        try FileManager.default.copyItem(at: script, to: scriptStage)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        let stagedContext = try GameProjectContext(
            projectID: request.context.projectID, owner: request.context.owner,
            rootURL: source, savedRevision: request.context.savedRevision,
            environmentID: request.context.environmentID)
        let plan = try GameGDevelopExportPlanner.plan(
            source: stagedContext, projectPath: projectPath, sdkRoot: sdk,
            workspace: stage.root, output: output, platform: .linuxX86_64,
            exportScriptURL: scriptStage)
        let relativeWorkspace = try Self.relativePath(stage.root, under: shellContext.workspaceRoot)
        for command in plan.commands {
            try Task.checkCancellation()
            let arguments = command.arguments.map {
                Self.guestPath(appValue: $0, stage: stage.root,
                               workspace: shellContext.workspaceRoot,
                               guestWorkspace: shellContext.guestWorkspaceRoot)
            }
            let result = try await configuration.shell.run(
                .init(executable: command.executable, arguments: arguments, cwd: relativeWorkspace),
                context: shellContext)
            guard result.exitCode == 0 else {
                throw GameExecutionError.commandFailed(
                    "GDevelop export exited \(result.exitCode): \(Self.tail(result.stderr))")
            }
        }
        try Task.checkCancellation()
        try GameWorkspaceTree.publishContents(
            of: output, to: request.outputDirectory,
            expectedEntry: request.expectedEntry, limits: configuration.limits)
        // The external build directory is a private copy; add the reviewed
        // dormant bridge before the run package is sealed.
        _ = try GameGDevelopExportBridge.decorate(directory: request.outputDirectory)
        try await validateSelection(request)
        return try makeOutput(request, expectedEntry: request.expectedEntry,
                              evidence: ["gdevelop-5.6.287", "host-export",
                                         "floe-developer-bridge"],
                              wholeDigest: copiedSource.digest,
                              sourceTransport: "localPrepared")
    }

    private static func gdevelopProjectPath(in source: URL) throws -> GameRelativePath {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        let candidates = ["game.json"] + names.filter {
            $0.lowercased().hasSuffix(".json")
        }.sorted()
        for name in candidates {
            let url = source.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= 262_144 else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["gdVersion"] != nil, object["layouts"] != nil {
                return try GameRelativePath(name)
            }
        }
        throw GameExecutionError.prerequisite(
            "No standard GDevelop project (game.json with gdVersion/layouts) was found in the selected source.")
    }

    // MARK: - Licensed RPG Maker deployment

    private func runLicensedDeployment(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        guard let tool = configuration.licensedDeployment else {
            throw GameExecutionError.prerequisite(
                "\(request.engine.rawValue) Web export needs a user-supplied official editor/runtime deployment tool. Floe does not bundle or download it; configure the licensed tool to use this route.")
        }
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-licensed-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stagedSource = temporary.appendingPathComponent("source", isDirectory: true)
        let stagedOutput = temporary.appendingPathComponent("out", isDirectory: true)
        let copiedSource = try GameWorkspaceTree.copyTree(
            from: request.sourceRoot, to: stagedSource, limits: configuration.limits)
        try validatePrepared(request, digest: copiedSource.digest)
        try FileManager.default.createDirectory(at: stagedOutput, withIntermediateDirectories: false)
        let evidence = try await tool.run(.init(
            engine: request.engine, sourceRoot: stagedSource,
            outputURL: stagedOutput, entry: request.expectedEntry,
            engineVersion: nil, revision: request.context.savedRevision))
        try Task.checkCancellation()
        guard FileManager.default.fileExists(
            atPath: stagedOutput.appendingPathComponent(request.expectedEntry.value).path) else {
            throw GameExecutionError.artifactInvalid("licensed deployment did not produce \(request.expectedEntry.value)")
        }
        try GameWorkspaceTree.publishContents(
            of: stagedOutput, to: request.outputDirectory,
            expectedEntry: request.expectedEntry, limits: configuration.limits)
        try await validateSelection(request)
        return try makeOutput(request, expectedEntry: request.expectedEntry,
                              evidence: evidence,
                              wholeDigest: copiedSource.digest,
                              sourceTransport: "licensedLocal")
    }

    // MARK: - CI

    private func runCI(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput {
        guard let ci = configuration.ci else {
            throw GameExecutionError.prerequisite(
                "No GitHub Actions repository is configured for \(request.kind.rawValue). Connect the user's repository, or use a supported local toolchain.")
        }
        guard let artifact = GameCIWebArtifact.name(for: request.engine) else {
            throw GameExecutionError.prerequisite(
                "The catalog declares no reviewed CI Web artifact for \(request.engine.rawValue).")
        }
        let outcome = try await ci.build(
            engine: request.engine, sourceRoot: request.sourceRoot,
            revision: request.context.savedRevision, engineVersion: nil,
            artifactName: artifact, expectedEntry: request.expectedEntry,
            outputDirectory: request.outputDirectory,
            selection: request.selection)
        var evidence = outcome.evidence
        if let selection = request.selection {
            evidence.append("selected-root:" + (selection.gameRoot?.value ?? "."))
        }
        let selectedDigest = outcome.provenance.selectedSourceSHA256
        let provenance = try GameRunExternalBuildProvenance(
            schemaVersion: 1,
            gameRoot: outcome.provenance.gameRoot,
            selectedSourceDigest: selectedDigest.isEmpty ? nil : selectedDigest,
            wholeProjectDigest: outcome.provenance.sourceSHA256,
            preparedSourceDigest: request.selection?.prepared.digest
                ?? outcome.provenance.sourceSHA256,
            preparedTransform: request.selection?.prepared.transform.rawValue
                ?? GameRunPreparedSourceTransform.byteIdenticalCopy.rawValue,
            ciJobID: outcome.jobID,
            sourceTransport: "ciRepository")
        return try GameRunExternalBuildOutput(
            directory: request.outputDirectory, entry: request.expectedEntry,
            evidence: evidence, provenance: provenance)
    }

    // MARK: - Selection/fence helpers

    private func liveContext(_ captured: GameProjectContext) async throws
        -> GameProjectContext {
        guard let currentContext = configuration.currentContext else { return captured }
        return try await currentContext(captured)
    }

    private func validateSelection(_ request: GameRunExternalBuildRequest) async throws {
        guard let selection = request.selection else { return }
        let current: GameProjectContext
        do { current = try await liveContext(request.context) }
        catch {
            throw GameExecutionError.prerequisite(
                "The game project could not be revalidated: \(error)")
        }
        do { try selection.validate(liveContext: current) }
        catch {
            throw GameExecutionError.prerequisite(String(describing: error))
        }
    }

    private func validatePrepared(_ request: GameRunExternalBuildRequest,
                                  digest: String) throws {
        guard let selection = request.selection else { return }
        do { try selection.validatePreparedDigest(digest) }
        catch {
            throw GameExecutionError.artifactInvalid(String(describing: error))
        }
    }

    private func makeOutput(_ request: GameRunExternalBuildRequest,
                            expectedEntry: GameRelativePath,
                            evidence: [String],
                            wholeDigest: String,
                            sourceTransport: String) throws
        -> GameRunExternalBuildOutput {
        let selection = request.selection
        let provenance = try GameRunExternalBuildProvenance(
            schemaVersion: 1,
            gameRoot: selection?.gameRoot?.value ?? "",
            selectedSourceDigest: selection?.selectedSourceDigest,
            wholeProjectDigest: selection?.wholeProjectDigest ?? wholeDigest,
            preparedSourceDigest: selection?.prepared.digest ?? wholeDigest,
            preparedTransform: selection?.prepared.transform.rawValue
                ?? GameRunPreparedSourceTransform.byteIdenticalCopy.rawValue,
            ciJobID: nil,
            sourceTransport: sourceTransport)
        return try GameRunExternalBuildOutput(
            directory: request.outputDirectory, entry: expectedEntry,
            evidence: evidence, provenance: provenance)
    }

    // MARK: - Staging helpers

    private struct Stage {
        let root: URL
    }

    private func makeStage(near workspace: URL) throws -> Stage {
        let root = workspace.appendingPathComponent(".floe-game-build-" + UUID().uuidString.lowercased(),
                                                    isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw GameExecutionError.invalidConfiguration("staging identity collision")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return .init(root: root)
    }

    private func ensureOutputIsOutsideSource(_ request: GameRunExternalBuildRequest) throws {
        let output = request.outputDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        for source in [request.sourceRoot, request.projectRootURL] {
            let path = source.standardizedFileURL.resolvingSymlinksInPath().path
            guard output != path, !output.hasPrefix(path + "/") else {
                throw GameExecutionError.outputEscaped("output is inside the source tree")
            }
        }
    }

    private static func relativePath(_ url: URL, under root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else {
            throw GameExecutionError.outputEscaped("path is outside the workspace")
        }
        return String(path.dropFirst(base.count))
    }

    private static func guestPath(appValue: String, stage: URL, workspace: URL,
                                  guestWorkspace: String) -> String {
        let stagePath = stage.standardizedFileURL.path
        let stageRelative = (try? relativePath(stage, under: workspace)) ?? ""
        let base = guestWorkspace + "/" + stageRelative
        if appValue == stagePath { return base }
        if appValue.hasPrefix(stagePath + "/") {
            return base + "/" + String(appValue.dropFirst(stagePath.count + 1))
        }
        return appValue
    }

    private static func tail(_ data: Data) -> String {
        let text = String(decoding: data.suffix(2_048), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no stderr)" : text
    }
}
