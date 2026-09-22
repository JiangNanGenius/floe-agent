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
    /// Verified Linux guest image storage (import/remove/status). Set by the
    /// app assembly on the same artifact root as the guest image resolver.
    private var linuxImages: LinuxGuestImageInstallationService?
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
    func stopEnvironment(id: String) async throws {
        // Stop the guest before the layer goes cold: its console may still be
        // executing with the writable layer attached.
        if let guests = currentLinuxCommandService() as? any LinuxGuestControlling {
            await guests.stopGuest(environmentID: id)
            await LinuxPortForwardCenter.shared.guestStopped(environmentID: id)
        }
        try await managementService().stopEnvironment(id: id)
    }
    /// Resuming a Linux environment starts its guest. If the guest cannot
    /// start (for example no qualified image exists yet), the environment goes
    /// back to stopped and the honest reason is thrown, so the record never
    /// claims an active Linux environment without a guest behind it.
    func resumeEnvironment(id: String) async throws {
        try await managementService().resumeEnvironment(id: id)
        guard currentLinuxCommandService() is any LinuxGuestControlling else { return }
        do {
            _ = try await startLinuxGuest(id: id, taskID: nil)
        } catch {
            try? await managementService().stopEnvironment(id: id)
            throw error
        }
    }
    func deleteEnvironment(id: String) async throws {
        try await managementService().deleteEnvironment(id: id)
        // A deleted environment has no future VM to restore: forget its rules.
        await LinuxPortForwardCenter.shared.forget(environmentID: id)
    }
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

    /// The local-service supervisor inside the injected Linux runner, when the
    /// backend supports guest services. `exec.localService` routes through
    /// this for Linux environments so Node/Python services run in the guest.
    func linuxLocalServiceController() -> (any LinuxGuestLocalServiceControlling)? {
        lock.withLock { linuxCommandService as? any LinuxGuestLocalServiceControlling }
    }

    /// The Linux guest controller (start/stop/status/forward) when this build
    /// has a Linux backend. Build 222 port-forward restoration and the
    /// background surface read/observe it instead of touching the concrete
    /// TinyEMU type.
    func linuxGuestController() -> (any LinuxGuestControlling)? {
        lock.withLock { linuxCommandService as? any LinuxGuestControlling }
    }

    /// A command runner for bounded guest reads (the background surface's
    /// active-command probe). The same injected service the tools use.
    func linuxCommandRunner() -> (any LinuxCommandRunning)? {
        lock.withLock { linuxCommandService }
    }

    /// Injected verified image storage (same artifact root as the resolver).
    func setLinuxImageService(_ service: LinuxGuestImageInstallationService?) {
        lock.withLock { linuxImages = service }
    }

    /// Real image state for the environment UI: manifest present, digest
    /// verification failure, and whether this build may distribute it.
    func linuxImageStatus(id: String?) async -> LinuxGuestImageInstallationService.ImageStatus? {
        guard let id, let images = lock.withLock({ linuxImages }) else { return nil }
        return await images.status(id: id)
    }

    /// True when this build has injected verified image storage. The settings
    /// UI offers the download entry only when storage really exists, so the
    /// button never promises an install this build cannot perform.
    func linuxGuestImageStorageAvailable() -> Bool {
        lock.withLock { linuxImages != nil }
    }

    /// Explicit runner-update state for the installed component, read from
    /// the image manifest's optional runner metadata. nil when the component
    /// is current, not installed, or carries no runner record.
    func linuxComponentUpdateNeeded(id: String?) async -> String? {
        guard let id, let images = lock.withLock({ linuxImages }) else { return nil }
        let manifest = images.imagesDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let data = try? Data(contentsOf: manifest)
        return LinuxComponentUpdatePolicy.updateNeededReason(manifestData: data)
    }

    /// Narrow install entry for the pinned Floe Linux image, reachable from
    /// environment settings. It uses the same verified storage and the same
    /// bounded HTTPS downloader as `floe-env image install`; the id must be a
    /// pinned catalog entry (installTrustedImage refuses anything else), and
    /// nothing is written into an environment layer — the image belongs to the
    /// App and is shared by every Linux environment.
    func installLinuxGuestImage(
        id: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> String {
        guard let images = lock.withLock({ linuxImages }) else {
            throw FloeError.invalidConfiguration(String(localized: "environment.backend.image_store_unavailable"))
        }
        let image = try await images.installTrustedImage(
            id: id,
            downloader: LinuxGuestImageHTTPDownloader(),
            onProgress: onProgress
        )
        return image.id
    }

    /// Explicit environment preparation: downloads, verifies and installs
    /// the pinned App-shared Linux image. Used by the `environment.prepareLinux`
    /// tool and by Linux-routed execution before it resumes the original
    /// command. No arbitrary image URL or install script is accepted.
    func prepareLinuxEnvironment(
        cancellation: CancellationToken,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> String {
        let imageID = LinuxGuestImageDistributionCatalog.defaultImageID
        guard let images = lock.withLock({ linuxImages }) else {
            throw FloeError.invalidConfiguration(String(localized: "environment.backend.image_store_unavailable"))
        }
        let current = await images.status(id: imageID)
        if current.installed && current.verificationFailure == nil {
            return "Linux image \(imageID) is already installed"
        }
        let jobID = "linux-image:" + imageID
        // One shared, cancellable job whether the user pressed the card or
        // first Linux use (shell, Python, services, apt/npm) auto-prepares:
        // two callers never start two downloads and both see progress.
        return try await EnvironmentPackageJobs.shared.runShared(
            id: jobID,
            title: String(format: String(localized: "environment.backend.image_download_title"), imageID)
        ) {
            try await withTaskCancellationHandler {
                let image = try await images.installTrustedImage(
                    id: imageID,
                    downloader: LinuxGuestImageHTTPDownloader(),
                    onProgress: { received, expected in
                        onProgress(received, expected)
                        guard expected > 0 else { return }
                        let fraction = min(1, Double(received) / Double(expected))
                        Task { @MainActor in
                            EnvironmentPackageJobs.shared.reportProgress(id: jobID, fraction: fraction)
                        }
                    }
                )
                return "Linux image \(image.id) installed and verified"
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    /// `floe-env image status|import|install|remove` — the reachable image
    /// entry. `install` downloads the catalog-pinned Floe archive; `import`
    /// takes an already-downloaded zip plus its SHA-512, which is what a local
    /// qualification run produces.
    func runImageCommand(arguments: [String]) async -> (output: String, exitCode: Int32) {
        let usage = """
        usage: floe-env image status <id>
               floe-env image import <id> <archive.zip> <sha512>
               floe-env image install <id>          (pinned Floe archive only)
               floe-env image remove <id>
        """
        guard let images = lock.withLock({ linuxImages }) else {
            return ("floe-env image: image storage is unavailable in this build (no durable artifact root); native environments are unchanged", 1)
        }
        let args = Array(arguments.dropFirst())
        guard args.count >= 2 else { return (usage, 2) }
        let action = args[1]
        do {
            switch action {
            case "status":
                guard args.count == 3 else { return (usage, 2) }
                let status = await images.status(id: args[2])
                var lines = [
                    "image \(status.id): \(status.installed ? "installed" : "not installed")",
                    "distributable: \(status.distributable ? "yes" : "no (no pinned Floe archive)")"
                ]
                if let failure = status.verificationFailure { lines.append("verification: \(failure)") }
                else if status.installed { lines.append("verification: ok (artifacts match the qualification record)") }
                if let image = status.image {
                    lines.append("qualificationRun: \(image.qualificationRun ?? "-")")
                    lines.append("cmdline: \(image.effectiveCmdline)")
                }
                return (lines.joined(separator: "\n"), 0)
            case "import":
                guard args.count == 5 else { return (usage, 2) }
                guard let archiveURL = authorizedImageArchivePath(args[3]) else {
                    return ("floe-env image: place the archive inside the current workspace or the image directory", 1)
                }
                let image = try await images.importArchive(at: archiveURL, expectedSHA512: args[4])
                return ("installed \(image.id) (verified artifacts; qualificationRun=\(image.qualificationRun ?? "-"))", 0)
            case "install":
                guard args.count == 3 else { return (usage, 2) }
                let image = try await images.installTrustedImage(id: args[2], downloader: LinuxGuestImageHTTPDownloader())
                return ("installed \(image.id) from the pinned Floe archive", 0)
            case "remove":
                guard args.count == 3 else { return (usage, 2) }
                try await images.removeImage(id: args[2])
                return ("removed image \(args[2])", 0)
            default:
                return (usage, 2)
            }
        } catch {
            return ("floe-env image: " + SecretRedactor.redact(error.localizedDescription), 1)
        }
    }

    /// Image archives may be read only from the current workspace or from the
    /// app's own image directory; an arbitrary host path is not an import
    /// source.
    private func authorizedImageArchivePath(_ path: String) -> URL? {
        guard let images = lock.withLock({ linuxImages }) else { return nil }
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var allowed: [URL] = [images.imagesDirectory]
        if let root = FloeShellCommandRegistry.shared.context?.rootURL {
            allowed.append(root)
        }
        for base in allowed {
            let resolved = base.resolvingSymlinksInPath().standardizedFileURL
            if candidate.path.hasPrefix(resolved.path + "/") { return candidate }
        }
        return nil
    }

    /// True when a running Linux guest backs this environment. The package UI
    /// reads real guest state only when this is true; otherwise it says a
    /// Linux environment is required instead of showing a host-side catalog.
    func linuxEnvironmentAvailable(id: String?) async -> Bool {
        guard let id, let service = currentLinuxCommandService() else { return false }
        return await service.supports(environmentID: id)
    }

    /// Real guest state for honest UI: nil when no Linux runner is injected.
    /// `lastError` carries the recorded reason a guest cannot start (for
    /// example an unqualified image).
    func linuxEnvironmentStatus(id: String?) async -> LinuxGuestStatus? {
        guard let id, let guests = currentLinuxCommandService() as? any LinuxGuestControlling else { return nil }
        return await guests.guestStatus(environmentID: id)
    }

    /// User-reachable backend selection for one environment. Switching away
    /// from `linuxVM` stops the guest first; switching to `linuxVM` records
    /// the choice and tries to start the guest, throwing the real reason when
    /// it cannot (the record keeps the selection so apt/dpkg never fall back
    /// to host-layer writes for a Linux environment).
    func setEnvironmentExecutionBackend(id: String, backend: EnvironmentExecutionBackend?) async throws {
        guard let registry else {
            throw FloeError.invalidConfiguration("container support is not configured in this build")
        }
        let guests = currentLinuxCommandService() as? any LinuxGuestControlling
        if backend != .linuxVM {
            await guests?.stopGuest(environmentID: id)
            // A different backend must not reuse the Linux environment's
            // shared-Python or Node resolution.
            await LinuxGuestPythonProvisioner.shared.forget(environmentID: id)
            await LinuxGuestNodeProvisioner.shared.forget(environmentID: id)
        }
        try await registry.setExecutionBackend(id: id, backend: backend)
        if backend == .linuxVM, guests != nil {
            _ = try await startLinuxGuest(id: id, taskID: nil)
        }
    }

    /// `floe-env backend <id> native|linux` — the reachable selection entry
    /// (also usable by the settings UI through setEnvironmentExecutionBackend).
    func runBackendCommand(arguments: [String]) async -> (output: String, exitCode: Int32) {
        guard arguments.count >= 3 else {
            return ("usage: floe-env backend <id|owner-id> native|linux", 2)
        }
        let selector = arguments[1]
        let raw = arguments[2].lowercased()
        let backend: EnvironmentExecutionBackend?
        switch raw {
        case "native", "posix": backend = .native
        case "linux", "linuxvm", "linux-vm": backend = .linuxVM
        default:
            return ("floe-env backend: expected native or linux, got '\(arguments[2])'", 2)
        }
        do {
            let id = try await resolveEnvironmentID(selector: selector)
            try await setEnvironmentExecutionBackend(id: id, backend: backend)
            if backend == .linuxVM, let status = await linuxEnvironmentStatus(id: id) {
                if status.running {
                    return ("environment \(id) executionBackend=linuxVM; guest running", 0)
                }
                let reason = status.lastError ?? "guest is not running"
                return ("environment \(id) executionBackend=linuxVM; guest not started: \(reason)", 3)
            }
            return ("environment \(id) executionBackend=\(backend?.rawValue ?? "native")", 0)
        } catch {
            return ("floe-env backend: \(error.localizedDescription)", 100)
        }
    }

    private func resolveEnvironmentID(selector: String) async throws -> String {
        guard let registry else {
            throw FloeError.invalidConfiguration("container support is not configured in this build")
        }
        if await registry.record(id: selector) != nil { return selector }
        if let record = await registry.containersOwned(by: selector).first { return record.id }
        throw FloeError.notFound("environment \(selector)")
    }

    /// True when the injected runner owns the environment as a Linux guest,
    /// even if the guest is not running yet. The shell uses this to keep
    /// host-side data-only dpkg operations out of Linux environments, and the
    /// UI uses it to ask for a Linux start instead of reporting that Linux
    /// does not exist on this device.
    func linuxEnvironmentOwned(id: String?) async -> Bool {
        guard let id, let service = currentLinuxCommandService() else { return false }
        return await service.ownsLinuxEnvironment(environmentID: id)
    }

    /// Host URL of an environment's writable layer (legacy package seeding,
    /// diagnostics). Nil for unknown environments.
    func layerURL(for environmentID: String) async -> URL? {
        guard let registry = lock.withLock({ registry }) else { return nil }
        return await registry.layerURL(for: environmentID)
    }

    /// Starts an owned Linux guest on demand (lazy activation) and seeds
    /// preserved native-era Python packages into the guest venv after a cold
    /// start. Throws the engine's honest reason when the guest cannot start;
    /// returns false when the environment is not Linux-owned.
    @discardableResult
    func startLinuxGuest(id: String, taskID: String? = nil) async throws -> Bool {
        guard let service = currentLinuxCommandService() else {
            throw FloeError.invalidConfiguration(String(localized: "environment.backend.image_store_unavailable"))
        }
        guard await service.ownsLinuxEnvironment(environmentID: id) else { return false }
        guard let guests = service as? any LinuxGuestControlling else {
            throw FloeError.invalidConfiguration(String(localized: "environment.backend.image_store_unavailable"))
        }
        if await guests.guestIsRunning(environmentID: id) { return true }
        _ = try await guests.startGuest(environmentID: id, taskID: taskID)
        await LegacyPythonPackageMigration.seedIfNeeded(environmentID: id, runner: service)
        // Build 222: a started VM restores its persisted port-forward rules,
        // remapping any fixed port that is already taken.
        await LinuxPortForwardCenter.shared.applyRules(environmentID: id)
        return true
    }

    /// The single lazy-activation entry used by shell routing, guest Python,
    /// services and package commands: start when owned-but-stopped, seed
    /// legacy packages after a cold start, surface the honest reason
    /// otherwise.
    func activateLinuxGuest(id: String) async throws {
        guard let service = currentLinuxCommandService() else {
            throw FloeError.invalidConfiguration(String(localized: "environment.backend.image_store_unavailable"))
        }
        try await LinuxGuestActivator.ensureRunning(
            environmentID: id,
            guests: service,
            controller: service as? any LinuxGuestControlling,
            onColdStart: { environmentID in
                await LegacyPythonPackageMigration.seedIfNeeded(environmentID: environmentID, runner: service)
            }
        )
        await LinuxPortForwardCenter.shared.applyRules(environmentID: id)
    }

    /// Every Linux-required entry point (shell, guest Python, local services,
    /// apt/node/pip commands) goes through this: activate, and when the only
    /// obstacle is a missing/unverified image run the same preparation flow
    /// the model tool uses, then activate once more. Callers therefore never
    /// need tools.list, an explicit prepareLinux decision or a separate
    /// download step; the user sees the shared, cancellable install job.
    func activateLinuxGuestWithPreparation(
        id: String,
        cancellation: CancellationToken? = nil
    ) async throws {
        do {
            try await activateLinuxGuest(id: id)
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error else { throw error }
            let token = cancellation ?? CancellationToken()
            _ = try await prepareLinuxEnvironment(cancellation: token)
            try await activateLinuxGuest(id: id)
        }
    }

    /// First environment record configured with the Linux backend, if any.
    /// Used by UI that must attach the shared component card to one real
    /// environment instead of inventing a guest state.
    func firstLinuxEnvironmentID() async -> String? {
        guard let reports = try? await environmentReports() else { return nil }
        return reports.first { $0.record.effectiveExecutionBackend == .linuxVM && $0.record.state != .deleting }?.id
    }

    /// Real guest status for the execution-environment screen. nil when this
    /// build/service cannot answer for the id.
    func linuxGuestStatus(id: String?) async -> LinuxGuestStatus? {
        guard let id, let guests = currentLinuxCommandService() as? any LinuxGuestControlling else { return nil }
        return await guests.guestStatus(environmentID: id)
    }

    /// Explicit stop entry for the settings screen. Honest no-op when the
    /// controller is unavailable; the caller re-reads the real status after.
    func stopLinuxGuest(id: String) async {
        guard let guests = currentLinuxCommandService() as? any LinuxGuestControlling else { return }
        await guests.stopGuest(environmentID: id)
        // The engine drops the VM's forwards with it; clear the applied view
        // but keep the durable rules.
        await LinuxPortForwardCenter.shared.guestStopped(environmentID: id)
    }

    /// Runs one command inside the environment's Linux guest with exactly the
    /// argv the caller supplies: no command-name or argument rewriting. An
    /// owned-but-stopped guest is started on demand (lazy activation); a
    /// start failure surfaces the engine's honest reason.
    func runLinuxCommand(
        id: String,
        argv: [String],
        timeout: TimeInterval = 300,
        maxOutputBytes: Int = 256 * 1024,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxCommandResult {
        guard !argv.isEmpty else {
            throw FloeError.validationFailed(String(localized: "environment.packages.linux.command_missing"))
        }
        guard let service = currentLinuxCommandService() else {
            throw FloeError.validationFailed(String(localized: "environment.packages.linux.guest_not_running"))
        }
        do {
            try await activateLinuxGuestWithPreparation(id: id, cancellation: cancellation)
        } catch {
            throw FloeError.validationFailed(error.localizedDescription)
        }
        return try await service.run(
            environmentID: id,
            argv: argv,
            workingDirectory: nil,
            standardInput: nil,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }

    func registerCommands(in commandRegistry: FloeShellCommandRegistry) {
        lock.lock()
        let envCommand = self.envCommand
        let aptEngine = self.aptEngine
        let contextProvider = self.contextProvider
        lock.unlock()

        commandRegistry.register("floe-env") { arguments, stdout, stderr in
            if arguments.first == "backend" {
                let result = await FloePlatformServices.shared.runBackendCommand(arguments: arguments)
                FloeShellWrite(result.exitCode == 0 ? stdout : stderr, result.output + "\n")
                return result.exitCode
            }
            if arguments.first == "image" {
                let result = await FloePlatformServices.shared.runImageCommand(arguments: arguments)
                FloeShellWrite(result.exitCode == 0 ? stdout : stderr, result.output + "\n")
                return result.exitCode
            }
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
                // Lazy activation plus first-use preparation: an owned guest
                // is started on demand, and a missing/unverified image runs
                // the same shared download flow the model tool uses. A
                // failure is printed with the command name instead of being
                // flattened into "not running".
                if let environmentID = invocation?.environment?.id,
                   await FloePlatformServices.shared.linuxEnvironmentOwned(id: environmentID) {
                    do {
                        try await FloePlatformServices.shared.activateLinuxGuestWithPreparation(
                            id: environmentID,
                            cancellation: invocation?.cancellation
                        )
                    } catch {
                        FloeShellWrite(stderr, "\(name): \(error.localizedDescription)\n")
                        return 127
                    }
                }
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
                // A Linux-backed environment must never fall back to host-side
                // layer writes: its package state lives inside the guest. Only
                // non-Linux environments keep the reviewed data-only archive
                // operations of PackagesCLI.
                let ownedByLinux = await FloePlatformServices.shared.linuxEnvironmentOwned(id: invocation?.environment?.id)
                if name == "dpkg" || name == "dpkg-deb", !ownedByLinux, let cli {
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
                let unavailable = ownedByLinux
                    ? LinuxShellCommandRouter.linuxNotRunningOutput(command: name)
                    : LinuxShellCommandRouter.linuxRequiredOutput(command: name)
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

    /// node/npm/npx/pnpm/pnpx/yarn run inside the task environment's Linux
    /// guest (Phase 2: the nodejs-mobile runtime left the app). Package
    /// changes go through the environment's managed guest transaction;
    /// everything else runs the guest's real CLI with the environment prefix
    /// on PATH/NODE_PATH and the workspace cwd mapped through the 9p shares.
    /// A native-backend environment gets the honest "Linux backend required"
    /// answer — there is no host Node to fall back to.
    private func registerNodeCommands(in commandRegistry: FloeShellCommandRegistry) {
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
                guard let environment = context.environment else {
                    FloeShellWrite(stderr, "\(name): no environment is attached\n")
                    return 2
                }
                guard let service = self.currentLinuxCommandService(),
                      await service.ownsLinuxEnvironment(environmentID: environment.id) else {
                    FloeShellWrite(stderr, "\(name): Node.js runs inside this environment's Linux guest; select the Linux backend for this environment (Settings → Execution) and install the Linux component\n")
                    return 127
                }
                do {
                    try await self.activateLinuxGuestWithPreparation(
                        id: environment.id,
                        cancellation: context.cancellation
                    )
                } catch {
                    FloeShellWrite(stderr, "\(name): \(error.localizedDescription)\n")
                    return 127
                }
                let node: LinuxGuestNodeEnvironment
                do {
                    node = try await LinuxGuestNodeProvisioner.shared.ensure(
                        environmentID: environment.id,
                        runner: service,
                        cancellation: context.cancellation
                    )
                } catch is CancellationError {
                    return 130
                } catch {
                    FloeShellWrite(stderr, "\(name): \(error.localizedDescription)\n")
                    return 127
                }
                if name == "yarn" {
                    // yarn is not part of the guest's base distribution.
                    FloeShellWrite(stderr, "yarn: not bundled with the guest; install yarn in this environment (npm i -g yarn) or use npm/pnpm\n")
                    return 127
                }
                // pnpm is an optional guest manager; say so honestly when the
                // guest does not expose it.
                let executable: String
                switch name {
                case "node": executable = node.nodePath
                case "npm": executable = node.npmPath
                case "npx":
                    executable = node.npmPath.replacingOccurrences(of: "/npm$", with: "/npx")
                case "pnpm", "pnpx":
                    guard let pnpm = node.pnpmPath else {
                        FloeShellWrite(stderr, "\(name): pnpm is not installed in this Linux environment; install it with apt/npm or use npm\n")
                        return 127
                    }
                    executable = name == "pnpx" ? pnpm.replacingOccurrences(of: "/pnpm$", with: "/pnpx") : pnpm
                default:
                    executable = node.nodePath
                }
                let variables: [String: String] = [
                    "PATH": ([node.pathDirectory, LinuxGuestNodeEnvironment.guestBin]
                        + [LinuxGuestPythonEnvironment.guestVenvPath + "/bin", LinuxGuestNodeEnvironment.defaultGuestPath]).joined(separator: ":"),
                    "NODE_PATH": LinuxGuestNodeEnvironment.guestNodeModules,
                    "HOME": LinuxGuestMountPoint.environment + "/home",
                    "TMPDIR": LinuxGuestWritablePaths.tmp,
                    "TMP": LinuxGuestWritablePaths.tmp,
                    "TEMP": LinuxGuestWritablePaths.tmp,
                    "XDG_CACHE_HOME": LinuxGuestWritablePaths.xdgCache,
                    "npm_config_cache": LinuxGuestWritablePaths.npmCache,
                    "CI": "1",
                    "FLOE_ENVIRONMENT_ID": environment.id
                ]
                if name == "yarn" {
                    FloeShellWrite(stderr, "yarn: not bundled with the guest; install yarn in this environment (npm i -g yarn) or use npm/pnpm\n")
                    return 127
                }
                var argv: [String] = ["env"]
                argv.append(contentsOf: LinuxGuestEnvironmentEncoding.argv(variables) ?? [])
                argv.append(executable)
                argv.append(contentsOf: userArguments)
                let workingDirectory = await (service as? any LinuxGuestPathMapping)?
                    .linuxGuestPathMap(environmentID: environment.id)
                    .flatMap { $0.guestPath(forHostPath: context.workingDirectory.path) }
                if context.workingDirectory.path != context.rootURL.path, workingDirectory == nil {
                    FloeShellWrite(stderr, "\(name): the working directory is outside this environment's shared folders\n")
                    return 2
                }
                var standardInput: String?
                if let input = FloeShellCommandRegistry.input, !input.isTerminal {
                    guard let value = await input.readAsync(cancellation: context.cancellation) else {
                        if context.cancellation.isCancelled { return 130 }
                        FloeShellWrite(stderr, "\(name): stdin exceeds 256 KiB or could not be read\n")
                        return 2
                    }
                    standardInput = value
                }
                do {
                    let result = try await service.run(
                        environmentID: environment.id,
                        argv: argv,
                        workingDirectory: workingDirectory,
                        standardInput: standardInput,
                        timeout: 300,
                        maxOutputBytes: 256 * 1024,
                        cancellation: context.cancellation
                    )
                    if !result.stdout.isEmpty { FloeShellWrite(stdout, result.stdout.hasSuffix("\n") ? result.stdout : result.stdout + "\n") }
                    if !result.stderr.isEmpty { FloeShellWrite(stderr, result.stderr.hasSuffix("\n") ? result.stderr : result.stderr + "\n") }
                    return result.exitCode
                } catch FloeError.cancelled {
                    return 130
                } catch {
                    FloeShellWrite(stderr, "\(name): \(error.localizedDescription)\n")
                    return 1
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
