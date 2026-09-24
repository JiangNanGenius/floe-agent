// FloeApp — Linux guest backend assembly (TinyEMU RV64).
//
// Linux environments run their shell, Python and services inside one TinyEMU
// guest. This file builds the app-side backend:
//   - new and migrated legacy environment records select `.linuxVM`,
//     while explicitly selected native environments retain compatibility,
//   - the descriptor exports the environment layer and the workspace over
//     virtio-9p,
//   - `RoutingLocalShellBackend` sends exec.shell into the guest for Linux
//     environments and keeps the native ios_system substrate everywhere else.
//
// The image catalog reads verified downloadable component manifests from
// FloeAgent's app-owned LinuxGuest/images directory; starting a
// Linux environment without a qualified manifest fails with the recorded
// reason rather than falling back to the 2018 demo image. The backend keeps
// environment ownership even without a real artifact root; image resolution
// then reports unavailable. No request falls back to a temporary directory or
// a native interpreter because Linux image storage is unavailable.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloePersistence
import FloeTools

/// Maps Floe environment records onto Linux guest descriptors. Only
/// environments explicitly declared `executionBackend == .linuxVM` are owned
/// by the guest backend; deleted environments disappear immediately.
struct AppLinuxGuestEnvironmentProvider: LinuxGuestEnvironmentProviding {
    let registry: EnvironmentRegistry
    let defaultImageID: String
    /// Resolves the image whose kernel/BIOS a pinned environment boots with
    /// (its immutable template's root base image). nil/absent keeps the
    /// configured default image, exactly as before.
    let pinnedImageID: (@Sendable (String) async -> String?)?
    /// Durable workspace access (WorkspaceRecord/security-scoped bookmarks),
    /// injected at assembly time from the app's database. Injected rather
    /// than read from a lazily created UI center: a cold-start background
    /// guest start must be able to resolve an external workspace before any
    /// window has touched the workspace UI.
    let workspaceStore: any WorkspaceStore

    init(
        registry: EnvironmentRegistry,
        defaultImageID: String,
        pinnedImageID: (@Sendable (String) async -> String?)? = nil,
        workspaceStore: any WorkspaceStore
    ) {
        self.registry = registry
        self.defaultImageID = defaultImageID
        self.pinnedImageID = pinnedImageID
        self.workspaceStore = workspaceStore
    }

    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        guard let record = await registry.record(id: id),
              record.executionBackend == .linuxVM,
              record.state != .deleting else { return nil }

        let layer = await registry.layerURL(for: id)
        var shares: [LinuxGuestShare] = []
        if let layer {
            shares.append(LinuxGuestShare(tag: "floe-env", hostDirectory: layer))
        }
        if let workspace = try? await registry.workspaceRoot(for: id),
           !shares.contains(where: { $0.hostDirectory.standardizedFileURL == workspace.standardizedFileURL }) {
            shares.append(LinuxGuestShare(tag: "workspace", hostDirectory: workspace))
        }

        let imageID = await pinnedImageID?(record.id) ?? defaultImageID
        return LinuxGuestEnvironmentDescriptor(
            id: record.id,
            ownerID: record.ownerID,
            taskID: nil,
            writableDirectory: layer,
            shares: Array(shares.prefix(LinuxGuestShare.maximumShares)),
            imageID: imageID,
            ramMB: nil,
            // Linux environments need apt/pip to install python3 and packages.
            // Each admitted guest owns its network instance; the registry
            // controls concurrent VM admission and lifecycle.
            networkEnabled: true,
            serviceForwards: []
        )
    }

    /// Durable access for the workspace 9P share. The registry only stores a
    /// plain path, and an iOS external Files folder is only reachable while a
    /// security-scoped grant is held; without this, a guest booted after a
    /// relaunch (Settings resume, package job, terminal) would export a
    /// workspace the host cannot read. The environment's own layer/data dirs
    /// stay app-owned and need no lease. An external workspace whose grant
    /// cannot be re-established throws the registry's typed failure so the VM
    /// never boots against an unreadable share.
    func acquireShareAccess(
        environmentID: String,
        descriptor: LinuxGuestEnvironmentDescriptor
    ) async throws -> LinuxGuestShareAccessLease? {
        guard let workspace = descriptor.shares.first(where: { $0.tag == LinuxGuestShare.workspaceTag })
        else { return nil }
        do {
            return try await WorkspaceCenter.acquireExternalWorkspaceAccess(
                forCanonicalPath: workspace.hostDirectory.path,
                store: workspaceStore
            )
        } catch let error as ExternalWorkspaceAccessError {
            throw LinuxGuestError.shareAccessUnavailable(
                environmentID: environmentID,
                detail: error.localizedDescription
            )
        }
    }
}

/// Runtime v2 hooks the environment-creation service needs to pin a NEW
/// environment before its first boot. Closures over the one production
/// integrator/store; no second store or service.
struct LinuxOfficialTemplateRuntime: Sendable {
    /// Creates the durable v2 environment row (if absent) and pins the exact
    /// verified template version.
    let registerPinnedEnvironment: @Sendable (_ environmentID: String, _ name: String?, _ templateID: String, _ version: Int) async throws -> RuntimeV2TemplatePin
    /// The pinned environment's root base image id (the image whose
    /// kernel/BIOS the working disk boots with).
    let environmentBaseImageID: @Sendable (_ environmentID: String) async -> String?
    /// Removes a freshly created environment row after a failed creation
    /// attempt (rollback; never touches a pre-existing row).
    let rollbackEnvironment: @Sendable (_ environmentID: String) async -> Void
}

/// Runtime v2 verified-image truth for install-state composition. Once the
/// verified v2 migration moves the legacy image directory into its rollback
/// point, a legacy-only status read would wrongly report "not installed" and
/// offer a re-download of gigabytes the device already has. This provider
/// answers from the v2 store only — it never triggers a migration as a side
/// effect of a status read.
struct LinuxGuestRuntimeV2ImageStatus: Sendable {
    /// Non-migrating verified gate (`isImageVerifiedWithoutMigration`).
    let isVerified: @Sendable (String) async -> Bool
    /// `RuntimeV2Layout.expandedImagesDirectory`: the rebuildable view that
    /// carries the verbatim legacy manifest as `manifest.json`.
    let expandedImagesRoot: URL

    /// The verified legacy manifest of an already-migrated image, or nil when
    /// the v2 store does not hold this image verified.
    func verifiedImage(id: String) async -> LinuxGuestImage? {
        guard await isVerified(id) else { return nil }
        let manifestURL = expandedImagesRoot
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LinuxGuestImage.self, from: data)
    }
}

/// Builds the single injected Linux guest service for the app.
enum LinuxGuestBackendAssembly {
    /// Manifest id expected under `<artifact root>/LinuxGuest/images/<id>/`.
    /// The manifest must carry a passing modern-guest qualification record.
    static let defaultImageID = LinuxGuestImageDistributionCatalog.defaultImageID

    /// Keep environment ownership available even when durable image storage is
    /// unavailable, so a Linux-selected request cannot fall back to native.
    /// `workspaceStore` is the app's workspace database: the provider resolves
    /// durable access to external workspace 9P shares from it. It is injected
    /// here (not read from a lazily created UI center) so a cold-start guest
    /// start — background job, Settings resume, terminal — can re-establish
    /// the security scope before any window has opened the workspace UI.
    static func makeService(
        registry: EnvironmentRegistry,
        artifactRoot: URL?,
        workspaceStore: any WorkspaceStore
    ) -> TinyEMULinuxCommandService {
        let images: any LinuxGuestImageResolving
        let runtimeV2: (any LinuxGuestRuntimeV2Integrating)?
        var pinnedImageID: (@Sendable (String) async -> String?)?
        if let artifactRoot {
            let legacyRoot = artifactRoot
                .appendingPathComponent("LinuxGuest", isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
            let legacy = FileLinuxGuestImageResolver(root: legacyRoot)
            if let layout = try? RuntimeV2Layout.production() {
                let store = RuntimeV2Store(layout: layout)
                let integrator = RuntimeV2GuestIntegrator(
                    store: store,
                    legacyImagesRoot: legacyRoot
                )
                runtimeV2 = integrator
                images = RuntimeV2CompositeImageResolver(
                    expandedImagesRoot: layout.expandedImagesDirectory,
                    legacy: legacy,
                    verifiedGate: { imageID in await integrator.isImageVerified(imageID: imageID) }
                )
                // Install-state truth for Settings and the IDE capability
                // gate: after the verified migration moves the legacy image
                // directory aside, image status must come from the v2 store.
                FloePlatformServices.shared.setLinuxImageRuntimeV2(
                    LinuxGuestRuntimeV2ImageStatus(
                        isVerified: { imageID in
                            await integrator.isImageVerifiedWithoutMigration(imageID: imageID)
                        },
                        expandedImagesRoot: layout.expandedImagesDirectory
                    )
                )
                // C5: a pinned environment boots the immutable template's own
                // image (its root base image) instead of the default image.
                pinnedImageID = { environmentID in
                    await integrator.environmentTemplateBaseImageID(environmentID: environmentID)
                }
                // Official template distribution + registration through the
                // existing verified image store and template store.
                let imageService = LinuxGuestImageInstallationService(root: artifactRoot, limits: .standard)
                let officialTemplates = RuntimeV2OfficialTemplateService(
                    store: store,
                    importer: LinuxGuestImageTemplateAvailabilityAdapter(service: imageService),
                    downloader: LinuxGuestImageHTTPDownloader()
                )
                FloePlatformServices.shared.setLinuxOfficialTemplateService(officialTemplates)
                FloePlatformServices.shared.setLinuxOfficialTemplateRuntime(
                    LinuxOfficialTemplateRuntime(
                        registerPinnedEnvironment: { environmentID, name, templateID, version in
                            try await integrator.registerPinnedEnvironment(
                                environmentID: environmentID, name: name,
                                templateID: templateID, version: version
                            )
                        },
                        environmentBaseImageID: { environmentID in
                            await integrator.environmentTemplateBaseImageID(environmentID: environmentID)
                        },
                        rollbackEnvironment: { environmentID in
                            await integrator.rollbackPinnedEnvironment(environmentID: environmentID)
                        }
                    )
                )
            } else {
                runtimeV2 = nil
                images = legacy
            }
        } else {
            FloeLogger(category: .tools).warning(
                "Linux guest images unavailable: no durable artifact root"
            )
            images = UnavailableLinuxGuestImageResolver()
            runtimeV2 = nil
        }
        let guestRegistry = TinyEMULinuxGuestRegistry(
            environments: AppLinuxGuestEnvironmentProvider(
                registry: registry,
                defaultImageID: defaultImageID,
                pinnedImageID: pinnedImageID,
                workspaceStore: workspaceStore
            ),
            images: images,
            limits: .standard,
            factory: TinyEMUGuestSessionFactory(),
            runtimeV2: runtimeV2
        )
        return TinyEMULinuxCommandService(registry: guestRegistry)
    }

    /// Verified image storage on the same artifact root as the resolver: it
    /// is what `floe-env image …` and the environment UI read. nil without a
    /// durable artifact root; guest ownership remains available independently.
    static func makeImageService(artifactRoot: URL?) -> LinuxGuestImageInstallationService? {
        guard let artifactRoot else { return nil }
        return LinuxGuestImageInstallationService(root: artifactRoot, limits: .standard)
    }
}

private struct UnavailableLinuxGuestImageResolver: LinuxGuestImageResolving {
    func linuxGuestImage(id: String) async -> LinuxGuestImage? { nil }
    func linuxGuestImageVerificationFailure(id: String) async -> String? {
        "Linux guest image storage is unavailable"
    }
}

/// Routes one-shot shell runs by the request's environment runtime: Linux
/// environments execute inside their guest, every other environment keeps the
/// injected native backend. Interactive sessions retain the backend selected
/// at open time, including Linux PTY sessions.
struct RoutingLocalShellBackend: LocalShellBackend {
    let native: any LocalShellBackend
    let guests: any LinuxCommandRunning
    let guestBackend: LinuxGuestShellBackend
    /// Optional explicit environment preparation. When the image is not
    /// qualified, the backend prepares Linux once, then resumes.
    let prepareLinux: LinuxPreparationHandler?
    private let guestSessions = GuestSessionIDSet()

    init(native: any LocalShellBackend,
         guests: any LinuxCommandRunning,
         limits: LinuxGuestLimits = .standard,
         prepareLinux: LinuxPreparationHandler? = nil) {
        self.native = native
        self.guests = guests
        self.guestBackend = LinuxGuestShellBackend(runner: guests, limits: limits)
        self.prepareLinux = prepareLinux
    }

    /// Activates the guest; when the failure is an unqualified image and a
    /// preparation handler exists, prepares Linux once and retries.
    ///
    /// `taskID` is the executing logical run (`ShellRunRequest.runID`). A cold
    /// start records it as the guest's owner so a later local-model
    /// continuation of the SAME run can release its own transient guest
    /// without asking the user to stop a VM it just used.
    private func activateWithPreparation(
        environmentID: String,
        taskID: String?,
        cancellation: CancellationToken?
    ) async throws {
        do {
            try await FloePlatformServices.shared.activateLinuxGuest(id: environmentID, taskID: taskID)
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error else { throw error }
            guard let prepareLinux else { throw error }
            let token = cancellation ?? CancellationToken()
            _ = try await prepareLinux(
                LinuxPreparationRequest(environmentID: environmentID, cancellation: token)
            )
            try await FloePlatformServices.shared.activateLinuxGuest(id: environmentID, taskID: taskID)
        }
    }

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id,
              await guests.ownsLinuxEnvironment(environmentID: environmentID) else {
            return await native.run(request, cancellation: cancellation)
        }
        do {
            try await activateWithPreparation(
                environmentID: environmentID,
                taskID: request.runID?.uuidString,
                cancellation: cancellation
            )
        } catch {
            return .failed(message: error.localizedDescription)
        }
        return await guestBackend.run(request, cancellation: cancellation)
    }

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        guard let environmentID = request.toolEnvironment?.id,
              await guests.ownsLinuxEnvironment(environmentID: environmentID) else {
            return try await native.openSession(request, cancellation: cancellation)
        }
        // An interactive terminal is user-driven work: it never claims the
        // run-owned transient status (and an open terminal protects the guest
        // from scoped release anyway).
        try await activateWithPreparation(
            environmentID: environmentID, taskID: nil, cancellation: cancellation
        )
        let result = try await guestBackend.openSession(request, cancellation: cancellation)
        guestSessions.insert(request.sessionID)
        return result
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard guestSessions.contains(request.sessionID) else {
            return try await native.exchangeSession(request, cancellation: cancellation)
        }
        let result = try await guestBackend.exchangeSession(request, cancellation: cancellation)
        if !result.alive { guestSessions.remove(request.sessionID) }
        return result
    }

    func closeSession(sessionID: String) async {
        guard guestSessions.remove(sessionID) else {
            await native.closeSession(sessionID: sessionID)
            return
        }
        await guestBackend.closeSession(sessionID: sessionID)
    }

    func signalSession(sessionID: String, signal: ShellSignal) async {
        guard guestSessions.contains(sessionID) else {
            await native.signalSession(sessionID: sessionID, signal: signal)
            return
        }
        await guestBackend.signalSession(sessionID: sessionID, signal: signal)
    }

    func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard guestSessions.contains(sessionID) else {
            await native.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
            return
        }
        await guestBackend.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }
}

/// Session ids that belong to the Linux guest backend, so exchange/close/
/// signal/resize can be routed without re-resolving the environment.
final class GuestSessionIDSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    @discardableResult func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.remove(id) != nil
    }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}
#endif
