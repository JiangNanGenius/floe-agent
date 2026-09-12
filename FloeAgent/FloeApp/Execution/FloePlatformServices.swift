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

    struct EnvironmentReport: Identifiable, Sendable {
        var id: String { record.id }
        let record: ContainerRecord
        let packages: [InstalledPackage]
        let bytes: Int64
    }

    func prepareWorkspaceEnvironment(root: URL) async throws {
        guard let registry = lock.withLock({ registry }) else { return }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let owner = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        _ = try await registry.ensureProjectContainer(workspaceID: owner, workspaceRootPath: canonical.path)
    }

    func environmentReports() async throws -> [EnvironmentReport] {
        guard let registry = lock.withLock({ registry }) else {
            throw FloeError.invalidConfiguration("Environment service is unavailable")
        }
        try await registry.prepare()
        var reports: [EnvironmentReport] = []
        for record in await registry.all() {
            guard let root = await registry.layerURL(for: record.id) else { continue }
            let report = try await Task.detached(priority: .utility) {
                let manifest = try LayerManifest.loadChecked(from: root)
                var bytes: Int64 = 0
                if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) {
                    while let file = files.nextObject() as? URL {
                        try Task.checkCancellation()
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                        if values.isRegularFile == true && values.isSymbolicLink != true {
                            let (sum, overflow) = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                            guard !overflow else { throw FloeError.validationFailed("Environment size overflow") }
                            bytes = sum
                        }
                    }
                }
                return EnvironmentReport(record: record, packages: manifest?.packages ?? [], bytes: bytes)
            }.value
            reports.append(report)
        }
        return reports
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
                    containerRoot: context.environment?.writableLayerURL ?? context.rootURL,
                    workspaceRoot: context.rootURL
                )
                let request = NodeRunRequest(
                    entryScript: entry,
                    arguments: userArguments,
                    workingDirectory: context.workingDirectory,
                    environment: environment.merging(context.environment?.variables ?? [:]) { _, resolved in resolved },
                    timeout: 300,
                    maxOutputBytes: 256 * 1024
                )
                let outcome = await nodeRuntime.run(request, cancellation: context.cancellation)
                switch outcome {
                case .exited(let code, let out, let err, _, let truncated):
                    if !out.isEmpty { FloeShellWrite(stdout, out.hasSuffix("\n") ? out : out + "\n") }
                    if !err.isEmpty { FloeShellWrite(stderr, err.hasSuffix("\n") ? err : err + "\n") }
                    if truncated { FloeShellWrite(stderr, "[Node output truncated]\n") }
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
