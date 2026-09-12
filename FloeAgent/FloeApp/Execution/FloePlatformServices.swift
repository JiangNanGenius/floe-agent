// FloeApp — Platform services and shell commands for containers, apt/dpkg,
// media and Node. The app configures the engines once at startup; the shell
// command registry dispatches to them afterwards.

import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeMedia
import FloePackages
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
#endif

final class FloePlatformServices: @unchecked Sendable {
    static let shared = FloePlatformServices()

    private let lock = NSLock()
    private var registry: EnvironmentRegistry?
    private var lifecycle: ContainerLifecycle?
    private var cas: ContainerCAS?
    private var promote: ContainerPromote?
    private var envCommand: FloeEnvCommand?
    private var aptEngine: AptEngine?
    private var contextProvider: (@Sendable () async -> PackagesCLI.Context?)?
    private var mediaRenderer: Any?
    private var baseSliceURL: URL?
    private var configured = false

    func configure(
        registry: EnvironmentRegistry,
        lifecycle: ContainerLifecycle,
        cas: ContainerCAS,
        promote: ContainerPromote,
        aptEngine: AptEngine,
        contextProvider: @escaping @Sendable () async -> PackagesCLI.Context?,
        baseSliceURL: URL?
    ) {
        lock.lock()
        self.registry = registry
        self.lifecycle = lifecycle
        self.cas = cas
        self.promote = promote
        self.aptEngine = aptEngine
        self.contextProvider = contextProvider
        self.baseSliceURL = baseSliceURL
        self.envCommand = FloeEnvCommand(
            registry: registry,
            lifecycle: lifecycle,
            promote: promote,
            bundledBaseURL: baseSliceURL
        )
        self.configured = true
        lock.unlock()
    }

    var isConfigured: Bool {
        lock.lock(); defer { lock.unlock() }
        return configured
    }

    func registerCommands(in commandRegistry: FloeShellCommandRegistry) {
        lock.lock()
        let envCommand = self.envCommand
        let aptEngine = self.aptEngine
        let contextProvider = self.contextProvider
        lock.unlock()

        commandRegistry.register("floe-env") { arguments, stdout, stderr in
            guard let envCommand else {
                FloeShellWrite(stderr, "floe-env: container support is not configured in this build\n")
                return 1
            }
            let result = await envCommand.run(arguments)
            FloeShellWrite(stdout, result.output + "\n")
            return result.exitCode ?? 0
        }

        guard let aptEngine, let contextProvider else { return }
        let cli = PackagesCLI(engine: aptEngine, contextProvider: contextProvider)
        for name in ["apt", "apt-get", "apt-cache", "apt-mark", "dpkg", "dpkg-deb"] {
            commandRegistry.register(name) { arguments, stdout, stderr in
                let result = await cli.run(command: name, arguments: arguments)
                if !result.output.isEmpty {
                    let newline = result.output.hasSuffix("\n") ? "" : "\n"
                    FloeShellWrite(result.exitCode == 0 ? stdout : stderr, result.output + newline)
                }
                return result.exitCode
            }
        }

        registerNodeCommands(in: commandRegistry)
        registerMediaCommands(in: commandRegistry)
    }

    // MARK: - Node

    private func registerNodeCommands(in commandRegistry: FloeShellCommandRegistry) {
        let nodeRuntime = IOSSystemNodeRuntime.shared
        for name in ["node", "npm", "npx", "pnpm", "pnpx", "yarn"] {
            commandRegistry.register(name) { arguments, stdout, stderr in
                guard let context = FloeShellCommandRegistry.shared.context else {
                    FloeShellWrite(stderr, "\(name): no workspace is attached\n")
                    return 2
                }
                var userArguments = Array(arguments.dropFirst())
                let entry: String?
                if name == "node" {
                    entry = userArguments.first
                    if entry != nil { userArguments.removeFirst() }
                } else {
                    guard let toolPath = FloeNodeBundledToolPath(name) else {
                        FloeShellWrite(stderr, "\(name): the bundled \(name) entry point is missing from this build\n")
                        return 127
                    }
                    entry = toolPath
                }
                let environment = IOSSystemNodeRuntime.defaultEnvironment(
                    containerRoot: context.rootURL,
                    workspaceRoot: context.rootURL
                )
                let request = NodeRunRequest(
                    entryScript: entry,
                    arguments: userArguments,
                    workingDirectory: context.rootURL,
                    environment: environment,
                    timeout: 300,
                    maxOutputBytes: 256 * 1024
                )
                let outcome = await nodeRuntime.run(request, cancellation: context.cancellation)
                switch outcome {
                case .exited(let code, let out, let err, _):
                    if !out.isEmpty { FloeShellWrite(stdout, out.hasSuffix("\n") ? out : out + "\n") }
                    if !err.isEmpty { FloeShellWrite(stderr, err.hasSuffix("\n") ? err : err + "\n") }
                    return code
                case .timedOut(let out, let err, _):
                    if !out.isEmpty { FloeShellWrite(stdout, out) }
                    if !err.isEmpty { FloeShellWrite(stderr, err) }
                    FloeShellWrite(stderr, "\(name): timed out\n")
                    return 124
                case .cancelled:
                    return 130
                case .failed(let message):
                    FloeShellWrite(stderr, "\(name): \(message)\n")
                    return 127
                }
            }
        }
    }

    // MARK: - Media command bridges

    private func registerMediaCommands(in commandRegistry: FloeShellCommandRegistry) {
        #if canImport(AVFoundation)
        commandRegistry.register("ffprobe") { arguments, stdout, stderr in
            guard let context = FloeShellCommandRegistry.shared.context else {
                FloeShellWrite(stderr, "ffprobe: no workspace is attached\n")
                return 2
            }
            let path = arguments.dropFirst().last { !$0.hasPrefix("-") }
            guard let path else {
                FloeShellWrite(stderr, "usage: ffprobe <file>\n")
                return 2
            }
            do {
                let renderer = MediaRenderer(rootProvider: { context.rootURL })
                let report = try await renderer.inspect(path: path)
                FloeShellWrite(stdout, report.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n")
                return 0
            } catch {
                FloeShellWrite(stderr, "ffprobe: \(error.localizedDescription)\n")
                return 1
            }
        }
        commandRegistry.register("ffmpeg") { arguments, stdout, stderr in
            _ = arguments
            FloeShellWrite(stderr, """
            ffmpeg: this build uses the native media engine instead of the FFmpeg CLI.
            Use the video.* and audio.* tools with explicit parameters:
              video.inspect / video.edit / video.transcode / video.remux
              video.extractFrames / video.thumbnail / video.interpolate / video.superResolution
              audio.inspect / audio.edit
            Run media.capabilities first to see what this device supports. Missing parameters never default.

            """)
            _ = stdout
            return 1
        }
        #endif
    }

    /// Media commands are registered lazily because the renderer needs the
    /// current workspace root, which changes per run.
    func makeMediaRenderer(rootProvider: @escaping @Sendable () -> URL?) -> MediaRenderer? {
        #if canImport(AVFoundation)
        return MediaRenderer(rootProvider: rootProvider)
        #else
        return nil
        #endif
    }

    /// Model artifacts visible to `media.capabilities` (installed + available).
    func modelReport() async -> (installed: [MediaCapabilities.Model], available: [MediaCapabilities.Model]) {
        (( [], [] ))
    }
}
