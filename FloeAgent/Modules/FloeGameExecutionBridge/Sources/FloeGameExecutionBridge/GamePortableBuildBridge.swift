// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameBuildKit
import FloeGameCore
import FloeGamePortableKit

public struct GamePortableBuildConfiguration: Sendable {
    public let shell: any GameShellRunning
    /// Resolves a real saved run/lease for this build. It must not synthesize a
    /// run UUID or treat a missing Space conversation as executable authority.
    public let shellContext: GameShellContextProvider
    public let limits: GameExecutionLimits

    public init(shell: any GameShellRunning, shellContext: @escaping GameShellContextProvider,
                limits: GameExecutionLimits = .default) {
        self.shell = shell
        self.shellContext = shellContext
        self.limits = limits
    }
}

/// `GamePortableBuildPort` over the existing shell/lease seam. It executes the
/// already-typed LÖVE/Ren'Py plan; it does not add an interpreter or package
/// installer.
public actor GamePortableBuildBridge: GamePortableBuildPort {
    private let configuration: GamePortableBuildConfiguration

    public init(configuration: GamePortableBuildConfiguration) {
        self.configuration = configuration
    }

    public func execute(_ plan: GamePortableBuildPlan,
                        request: GamePortableBuildRequest) async throws -> GamePortableBuildOutput {
        try Task.checkCancellation()
        guard plan.entry.value.lowercased().hasSuffix(".html") else {
            throw GameExecutionError.invalidConfiguration("portable plan has no HTML entry")
        }
        let shellContext = try await configuration.shellContext()
        let stage = try makeStage(context: shellContext)
        defer { try? GameWorkspaceTree.removeOwnedDirectory(stage) }
        let source = stage.appendingPathComponent("source", isDirectory: true)
        let output = stage.appendingPathComponent("out", isDirectory: true)
        try GameWorkspaceTree.copyTree(from: request.project.rootURL, to: source,
                                       limits: configuration.limits)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        var resourcesStage: URL?
        if let resources = request.resources {
            try resources.verify()
            let destination = stage.appendingPathComponent("resources", isDirectory: true)
            try GameWorkspaceTree.copyTree(from: resources.rootURL, to: destination,
                                           limits: configuration.limits)
            resourcesStage = destination
        }
        var sdkStage: URL?
        if let sdk = request.sdkURL {
            let destination = stage.appendingPathComponent("sdk", isDirectory: true)
            try GameWorkspaceTree.copyTree(from: sdk, to: destination,
                                           limits: configuration.limits)
            sdkStage = destination
        }

        let guestSource = try guestPath(source, context: shellContext)
        let guestOutput = try guestPath(output, context: shellContext)
        let guestResources = try resourcesStage.map { try guestPath($0, context: shellContext) }
        let guestSDK = try sdkStage.map { try guestPath($0, context: shellContext) }
        let relativeSource = try relativePath(source, context: shellContext)
        var toolchain: [String] = []

        for step in plan.steps {
            try Task.checkCancellation()
            switch step.kind {
            case .archiveSource:
                let archive = output.appendingPathComponent("floe-game.love", isDirectory: false)
                _ = try GameArchiveExchange().archive(directory: source, to: archive)
                toolchain.append("love-source-archive")
            case .assembleFiles:
                throw GameExecutionError.unsupportedRoute(
                    "A host portable port received an on-device assembly step; use the deterministic portable assembler instead.")
            case .verifyArtifact:
                continue
            case .runNode, .runRenPy:
                guard let executable = step.executable, !executable.isEmpty else {
                    throw GameExecutionError.invalidConfiguration("portable command has no executable")
                }
                let arguments = try step.arguments.map {
                    try Self.expand($0, project: guestSource, output: guestOutput,
                                    resources: guestResources, sdk: guestSDK,
                                    title: request.title, memory: request.memoryBytes)
                }
                var resolvedExecutable = executable
                var workingDirectory = relativeSource
                if executable == "renpy.sh" {
                    guard let guestSDK, let sdkStage else {
                        throw GameExecutionError.prerequisite("Ren'Py SDK path is required")
                    }
                    resolvedExecutable = guestSDK + "/renpy.sh"
                    // Ren'Py resolves the "launcher" project against the cwd.
                    // The imported project is the explicit web_build argument.
                    workingDirectory = try relativePath(sdkStage, context: shellContext)
                }
                let result = try await configuration.shell.run(
                    .init(executable: resolvedExecutable, arguments: arguments, cwd: workingDirectory),
                    context: shellContext)
                guard result.exitCode == 0 else {
                    throw GameExecutionError.commandFailed(
                        "Portable \(plan.kind.rawValue) command exited \(result.exitCode): \(Self.tail(result.stderr))")
                }
                toolchain.append(plan.kind.rawValue)
            }
        }

        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: output.appendingPathComponent(plan.entry.value).path) else {
            throw GameExecutionError.artifactInvalid(
                "Portable build did not produce \(plan.entry.value)")
        }
        try GameWorkspaceTree.publishContents(
            of: output, to: request.outputURL, expectedEntry: plan.entry,
            limits: configuration.limits)
        return .init(directory: request.outputURL, entry: plan.entry, toolchain: toolchain)
    }

    private func makeStage(context: GameShellContext) throws -> URL {
        let root = context.workspaceRoot
            .appendingPathComponent(".floe-game-portable-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw GameExecutionError.invalidConfiguration("staging identity collision")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
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

    private func guestPath(_ url: URL, context: GameShellContext) throws -> String {
        context.guestWorkspaceRoot + "/" + (try relativePath(url, context: context))
    }

    private static func expand(_ value: String, project: String, output: String,
                               resources: String?, sdk: String?, title: String,
                               memory: Int) throws -> String {
        var result = value
        result = result.replacingOccurrences(of: "{{projectRoot}}", with: project)
        result = result.replacingOccurrences(of: "{{output}}", with: output)
        if result.contains("{{resources}}") {
            guard let resources else {
                throw GameExecutionError.prerequisite("portable build requires prepared resources")
            }
            result = result.replacingOccurrences(of: "{{resources}}", with: resources)
        }
        if result.contains("{{sdk}}") {
            guard let sdk else {
                throw GameExecutionError.prerequisite("portable build requires its pinned SDK")
            }
            result = result.replacingOccurrences(of: "{{sdk}}", with: sdk)
        }
        result = result.replacingOccurrences(of: "{{title}}", with: title)
        result = result.replacingOccurrences(of: "{{memory}}", with: String(memory))
        return result
    }

    private static func tail(_ data: Data) -> String {
        let text = String(decoding: data.suffix(2_048), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no stderr)" : text
    }
}
