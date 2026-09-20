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
    // Bump only when bundled runtime ABI/layer compatibility changes, never for an App build.
    static let environmentBaseRevision = "ios-v1-cpython313-node18204-wasi1"

    private let lock = NSLock()
    private var registry: EnvironmentRegistry?
    private var lifecycle: ContainerLifecycle?
    private var cas: ContainerCAS?
    private var promote: ContainerPromote?
    private var envCommand: FloeEnvCommand?
    private var aptEngine: AptEngine?
    private var contextProvider: (@Sendable () async -> PackagesCLI.Context?)?
    /// Injected Linux guest command runner (TinyEMU backend, supplied by the
    /// app integration). Nil until a Linux environment backend exists; the
    /// apt/dpkg shell commands then answer honestly that a Linux environment
    /// is required instead of pretending to manage packages on iOS.
    private var linuxCommandService: (any LinuxCommandRunning)?
    private var mediaRenderer: Any?
    private var baseSliceURL: URL?
    private var management: EnvironmentManagementService?
    private var languageManagement: EnvironmentLanguagePackageService?
    private var configured = false

    func configure(
        registry: EnvironmentRegistry,
        lifecycle: ContainerLifecycle,
        cas: ContainerCAS,
        promote: ContainerPromote,
        aptEngine: AptEngine,
        contextProvider: @escaping @Sendable () async -> PackagesCLI.Context?,
        baseSliceURL: URL?,
        languageManagement: EnvironmentLanguagePackageService
    ) {
        lock.lock()
        self.languageManagement = languageManagement
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
        self.management = EnvironmentManagementService(registry: registry, lifecycle: lifecycle, engine: aptEngine, baseSliceURL: baseSliceURL)
        self.configured = true
        lock.unlock()
    }

    struct EnvironmentReport: Identifiable, Sendable {
        var id: String { record.id }
        let record: ContainerRecord
        let packages: [InstalledPackage]
        let bytes: Int64
        var issue: String? = nil
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
            do {
                let report = try await Task.detached(priority: .utility) {
                    guard let manifest = try LayerManifest.loadChecked(from: root) else {
                        throw FloeError.validationFailed("环境清单缺失；数据已保留")
                    }
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
                    return EnvironmentReport(record: record, packages: manifest.packages, bytes: bytes)
                }.value
                reports.append(report)
            } catch is CancellationError { throw CancellationError() }
            catch { reports.append(EnvironmentReport(record: record, packages: [], bytes: record.bytes, issue: String(describing: error))) }
        }
        return reports
    }

    typealias PackageReport = EnvironmentManagementService.PackageReport
    typealias PackageAction = EnvironmentManagementService.PackageAction

    /// One installed package read straight from an environment layer manifest.
    struct LayerPackageSummary: Sendable {
        let environmentID: String
        let layerKind: LayerKind
        let name: String
        let version: String
    }

    /// Reads only the layer manifests (no file-size walk) for the
    /// execution-runtime inventory. A missing or malformed manifest is skipped
    /// instead of guessed; environment reports show the recovery state.
    func installedLayerPackages() async -> [LayerPackageSummary] {
        guard let registry = lock.withLock({ registry }) else { return [] }
        var result: [LayerPackageSummary] = []
        for record in await registry.all() {
            guard let root = await registry.layerURL(for: record.id),
                  let manifest = try? LayerManifest.loadChecked(from: root) else { continue }
            for package in manifest.packages {
                result.append(LayerPackageSummary(
                    environmentID: record.id,
                    layerKind: package.layer,
                    name: package.name,
                    version: package.version
                ))
            }
        }
        return result
    }
    private func managementService() throws -> EnvironmentManagementService {
        guard let service = lock.withLock({ management }) else { throw FloeError.invalidConfiguration("Environment service unavailable") }
        return service
    }
    func languagePackageService() throws -> EnvironmentLanguagePackageService {
        guard let service = lock.withLock({ languageManagement }) else {
            throw FloeError.invalidConfiguration("语言依赖管理尚未就绪")
        }
        return service
    }
    func packageReport(id: String) async throws -> PackageReport { try await managementService().packageReport(id: id) }
    func managePackage(id: String, action: PackageAction) async throws -> String { try await managementService().managePackage(id: id, action: action) }
    func stopEnvironment(id: String) async throws { try await managementService().stopEnvironment(id: id) }
    func resumeEnvironment(id: String) async throws { try await managementService().resumeEnvironment(id: id) }
    func deleteEnvironment(id: String) async throws { try await managementService().deleteEnvironment(id: id) }
    func saveEnvironmentTemplate(id: String, name: String) async throws { try await managementService().saveEnvironmentTemplate(id: id, name: name) }

    var isConfigured: Bool {
        lock.lock(); defer { lock.unlock() }
        return configured
    }

    /// Late-injection seam for the Linux guest command runner. The TinyEMU
    /// app integration sets this once its backend can own Linux environments;
    /// shell command handlers read it per invocation, so registration order
    /// does not matter.
    func setLinuxCommandService(_ service: (any LinuxCommandRunning)?) {
        lock.withLock { linuxCommandService = service }
    }

    /// Current Linux runner, read under the lock on every invocation.
    private func currentLinuxCommandService() -> (any LinuxCommandRunning)? {
        lock.withLock { linuxCommandService }
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

        registerPythonPackageCommands(in: commandRegistry)
        registerNodeCommands(in: commandRegistry)
        registerMediaCommands(in: commandRegistry)
        registerLinuxPackageCommands(in: commandRegistry, aptEngine: aptEngine, contextProvider: contextProvider)

    }

    /// apt/dpkg command names mean real Linux distribution packages only.
    /// When the shell's environment is a Linux guest backed by the injected
    /// runner, argv is forwarded to the guest verbatim. Otherwise the apt
    /// family fails honestly (no Linux environment), while dpkg/dpkg-deb keep
    /// their reviewed host-side data-only archive operations through
    /// PackagesCLI. WASM, Python and Node never resolve here.
    private func registerLinuxPackageCommands(
        in commandRegistry: FloeShellCommandRegistry,
        aptEngine: AptEngine?,
        contextProvider: (@Sendable () async -> PackagesCLI.Context?)?
    ) {
        let cli = aptEngine.flatMap { engine in
            contextProvider.map { PackagesCLI(engine: engine, contextProvider: $0) }
        }
        for name in LinuxShellCommandRouter.routedCommandNames {
            commandRegistry.register(name) { arguments, stdout, stderr in
                let invocation = FloeShellCommandRegistry.shared.context
                let router = LinuxShellCommandRouter(service: FloePlatformServices.shared.currentLinuxCommandService())
                if let result = await router.runIfSupported(
                    command: name,
                    arguments: arguments,
                    environmentID: invocation?.environment?.id,
                    workingDirectory: invocation?.workingDirectory.path,
                    cancellation: invocation?.cancellation
                ) {
                    if !result.stdout.isEmpty { FloeShellWrite(stdout, result.stdout.hasSuffix("\n") ? result.stdout : result.stdout + "\n") }
                    if !result.stderr.isEmpty { FloeShellWrite(stderr, result.stderr.hasSuffix("\n") ? result.stderr : result.stderr + "\n") }
                    return result.exitCode
                }
                if name == "dpkg" || name == "dpkg-deb", let cli {
                    // Host-side reviewed data-only .deb operations (extract,
                    // inspect, build, data-package install into an environment
                    // layer). Executable payloads are refused inside PackagesCLI.
                    let result = await cli.run(command: name, arguments: arguments,
                        cancellation: invocation?.cancellation)
                    if !result.output.isEmpty {
                        let newline = result.output.hasSuffix("\n") ? "" : "\n"
                        FloeShellWrite(result.exitCode == 0 ? stdout : stderr, result.output + newline)
                    }
                    return result.exitCode
                }
                let unavailable = LinuxShellCommandRouter.linuxRequiredOutput(command: name)
                FloeShellWrite(stderr, unavailable.stderr + "\n")
                return unavailable.exitCode
            }
        }
    }

    private func registerPythonPackageCommands(in registry: FloeShellCommandRegistry) {
        let manager = lock.withLock { languageManagement }
        for name in ["pip", "pip3"] {
            registry.register(name) { arguments, stdout, stderr in
                do {
                    guard let manager, let context = FloeShellCommandRegistry.shared.context, let environment = context.environment else {
                        throw FloeError.invalidConfiguration("当前 Shell 未绑定可安装依赖的环境")
                    }
                    let operation = try ManagedPythonPackageSpecParser.parseShell(arguments: Array(arguments.dropFirst()))
                    let output = try await manager.pythonFromShell(environment: environment, operation: operation, cancellation: context.cancellation)
                    if !output.isEmpty { FloeShellWrite(stdout, output.hasSuffix("\n") ? output : output + "\n") }
                    return 0
                } catch is CancellationError { return 130 }
                catch { FloeShellWrite(stderr, "\(name): \(error.localizedDescription)\n"); return 1 }
            }
        }
    }

    // MARK: - Node

    private func registerNodeCommands(in commandRegistry: FloeShellCommandRegistry) {
        let nodeRuntime = IOSSystemNodeRuntime.shared
        let languageManagement = lock.withLock { self.languageManagement }
        for name in ["node", "npm", "npx", "pnpm", "pnpx", "yarn"] {
            commandRegistry.register(name) { arguments, stdout, stderr in
                guard let context = FloeShellCommandRegistry.shared.context else {
                    FloeShellWrite(stderr, "\(name): no workspace is attached\n")
                    return 2
                }
                let userArguments = Array(arguments.dropFirst())
                if let manager = NodePackageManager(rawValue: name) {
                    do {
                        if let change = try NodePackageManagerPolicy.shellChange(arguments: userArguments,
                            directory: context.workingDirectory, workspace: context.rootURL) {
                            guard let languageManagement, let environment = context.environment else {
                                throw FloeError.invalidConfiguration("当前 Shell 未绑定可安装依赖的环境")
                            }
                            // The shell command named its manager explicitly.
                            // The configured environment default and the
                            // project's lock are automatic-selection hints
                            // for the UI/agent path; they must not silently
                            // substitute a different manager here, so
                            // `npm install` stays npm even in a pnpm project.
                            let selected = try NodePackageManagerPolicy.resolve(
                                .explicit(manager), workspace: context.rootURL)
                            let output = try await languageManagement.changeNodeFromShell(environment: environment,
                                change: change, manager: selected, cancellation: context.cancellation)
                            if !output.isEmpty { FloeShellWrite(stdout, output + "\n") }
                            return 0
                        }
                    } catch is CancellationError { return 130 }
                    catch { FloeShellWrite(stderr, "\(name): \(error.localizedDescription)\n"); return 1 }
                }
                let entry: String?
                if name == "node" {
                    // The persistent host parses Node's CLI options. Passing
                    // -v/-e as entryScript incorrectly resolves them as files.
                    entry = nil
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
                var variables = environment.merging(context.environment?.variables ?? [:]) { _, resolved in resolved }
                    .merging(context.shellVariables) { _, shell in shell }
                // Ownership metadata is supplied by the resolver, never by an export.
                if let id = context.environment?.id { variables["FLOE_ENVIRONMENT_ID"] = id }
                let liveInput: Int32?
                // Do not drain stdin before starting Node. A script may never
                // read it, or may produce output before its producer sends EOF.
                // The native pump retains its own descriptor and stops when
                // the Worker exits, including cancellation and timeout.
                if let stream = FloeShellCommandRegistry.input?.stream {
                    liveInput = fileno(stream)
                } else { liveInput = nil }
                let request = NodeRunRequest(
                    entryScript: entry,
                    arguments: userArguments,
                    workingDirectory: context.workingDirectory,
                    environment: variables,
                    stdin: nil,
                    stdinFileDescriptor: liveInput,
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
