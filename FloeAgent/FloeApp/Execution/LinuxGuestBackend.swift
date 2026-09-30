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

/// Dynamic, reconnect-safe resolver of the base image for a pinned
/// environment. The environment provider is created once at launch; reading
/// through this object lets a recoverable reconnect update how pins resolve
/// without rebuilding the provider or leaving a stale captured closure.
final class PinnedImageSource: @unchecked Sendable {
    private let sourceLock = NSLock()
    private var resolver: (@Sendable (String) async -> String?)?

    func set(_ resolver: (@Sendable (String) async -> String?)?) {
        sourceLock.withLock { self.resolver = resolver }
    }

    func baseImageID(for environmentID: String) async -> String? {
        let resolver = sourceLock.withLock { self.resolver }
        return await resolver?(environmentID)
    }
}

/// Maps Floe environment records onto Linux guest descriptors. Only
/// environments explicitly declared `executionBackend == .linuxVM` are owned
/// by the guest backend; deleted environments disappear immediately.
struct AppLinuxGuestEnvironmentProvider: LinuxGuestEnvironmentProviding {
    let registry: EnvironmentRegistry
    let defaultImageID: String
    /// Dynamic resolver for the image whose kernel/BIOS a pinned environment
    /// boots with (its immutable template's root base image). Read at
    /// descriptor-build time so reconnect takes effect; nil/absent keeps the
    /// configured default image.
    let pinnedImageSource: PinnedImageSource
    /// Durable workspace access (WorkspaceRecord/security-scoped bookmarks),
    /// injected at assembly time from the app's database. Injected rather
    /// than read from a lazily created UI center: a cold-start background
    /// guest start must be able to resolve an external workspace before any
    /// window has touched the workspace UI.
    let workspaceStore: any WorkspaceStore
    /// The run shape armed by `FloePlatformServices` for the start currently
    /// in flight (an accepted IDE script-run shape), or nil for every ordinary
    /// start. Read-only during descriptor build: a concurrent status probe must
    /// not consume what the start in flight still needs.
    let armedRunShape: (@Sendable (String) -> ShellGuestRunShapeIntent?)?

    init(
        registry: EnvironmentRegistry,
        defaultImageID: String,
        pinnedImageSource: PinnedImageSource,
        workspaceStore: any WorkspaceStore,
        armedRunShape: (@Sendable (String) -> ShellGuestRunShapeIntent?)? = nil
    ) {
        self.registry = registry
        self.defaultImageID = defaultImageID
        self.pinnedImageSource = pinnedImageSource
        self.workspaceStore = workspaceStore
        self.armedRunShape = armedRunShape
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

        let imageID = await pinnedImageSource.baseImageID(for: record.id) ?? defaultImageID
        // An accepted IDE script-run shape armed for the start in flight is
        // what this descriptor must carry: the typed vCPU/RAM request travels
        // to the registry's typed admission (and from there to the pool) as an
        // explicit environment-policy request, never as a hardcoded one-hart
        // default. With no armed shape the descriptor keeps its previous
        // nil values (worker default: one hart, the configured RAM default).
        let armed = armedRunShape?(record.id)
        return LinuxGuestEnvironmentDescriptor(
            id: record.id,
            ownerID: record.ownerID,
            taskID: nil,
            writableDirectory: layer,
            shares: Array(shares.prefix(LinuxGuestShare.maximumShares)),
            imageID: imageID,
            ramMB: armed?.request.memory.mb,
            vcpus: armed?.request.vcpus.count,
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
/// effect of a status read — and its health answers are derived from the
/// actual expanded bytes and blob availability, never from the registry row
/// alone.
struct LinuxGuestRuntimeV2ImageStatus: Sendable {
    /// Cooperative cancellation check threaded into long reconstructions.
    /// The integrator's `isCancelled` parameter is an escaping optional, and a
    /// closure literal's parameter forwards to an escaping parameter only when
    /// its own type is that same optional (implicitly escaping) function type:
    /// the stored boundary mirrors it. Callers still pass a real check; `nil`
    /// means "no cooperative check".
    typealias CancellationCheck = @Sendable () -> Bool
    /// Non-migrating verified gate (`isImageVerifiedWithoutMigration`).
    let isVerified: @Sendable (String) async -> Bool
    /// `RuntimeV2Layout.expandedImagesDirectory`: the rebuildable view that
    /// carries the verbatim legacy manifest as `manifest.json`.
    let expandedImagesRoot: URL
    /// SMP capability PROVEN by the verified image manifest (never the
    /// engine's capability query and never a loose manifest claim). Answers
    /// false for a missing/unverified image or an absent/false declaration.
    let smpCapability: @Sendable (String) async -> Bool
    /// Real-file health: registry + manifest + actual expanded bytes + blob
    /// availability; nil when the v2 store does not hold the image. The
    /// optional second argument is the owner's cooperative cancel check;
    /// `.cancelled` means the hash stopped without a verdict and the caller
    /// must abort, never treat it as verified or damaged.
    let health: @Sendable (String, CancellationCheck?) async -> LinuxImageHealthCheck?
    /// Explicit re-verification (drops the cached success fingerprint).
    let reverifyHealth: @Sendable (String, CancellationCheck?) async -> LinuxImageHealthCheck?
    /// Rebuilds the expanded view from verified blobs (no download).
    let reconstructExpanded: @Sendable (String, CancellationCheck?) async throws -> Void
    /// Same-id repair of a migrated image from a freshly verified legacy
    /// install (blobs re-placed, expanded rebuilt).
    let repairFromLegacyInstall: @Sendable (String, CancellationCheck?) async throws -> Void
    /// Durable repair exclusion for one environment after a stop that could
    /// not save its delta (nil = the environment is not repair-excluded).
    /// Inspection only: never changes state.
    let repairHoldStatus: @Sendable (String) async -> RuntimeV2RepairHoldStore.Hold?
    /// What a repair resolution would account for: the preserved bytes'
    /// layout-relative path, or nothing. Inspection only.
    let repairRecoverable: @Sendable (String) async -> RuntimeV2RepairHoldStore.RecoverableState
    /// The latest startup-recovery stage the shared preparation pass
    /// reported (nil before any pass). Diagnostic progress truth for the
    /// storage-initializing presentation; never a state machine.
    let preparationStage: @Sendable () async -> RuntimeV2Store.RecoveryStage?

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
        // Resolver + v2 substrate plus every hook come from one prepared
        // bundle, so launch assembly and recoverable reconnect never
        // diverge. Construction publishes nothing.
        let wiring: PreparedGuestWiring
        if let artifactRoot {
            let imageService = LinuxGuestImageInstallationService(root: artifactRoot, limits: .standard)
            wiring = prepareGuestWiring(artifactRoot: artifactRoot, imageService: imageService)
        } else {
            FloeLogger(category: .tools).warning(
                "Linux guest images unavailable: no durable artifact root"
            )
            wiring = PreparedGuestWiring(
                images: UnavailableLinuxGuestImageResolver(), runtimeV2: nil,
                runtimeV2Status: nil, pinnedProbe: nil,
                officialTemplates: nil, officialTemplateRuntime: nil
            )
        }
        let guestRegistry = TinyEMULinuxGuestRegistry(
            environments: AppLinuxGuestEnvironmentProvider(
                registry: registry,
                defaultImageID: defaultImageID,
                pinnedImageSource: FloePlatformServices.shared.linuxPinnedImageSource,
                workspaceStore: workspaceStore,
                // The shape claimed for the start in flight (an accepted IDE
                // script run): the descriptor it builds carries the typed
                // request so the registry/pool admit that shape explicitly.
                armedRunShape: { environmentID in
                    FloePlatformServices.shared.runShapeCenter.armedIntent(environmentID: environmentID)
                }
            ),
            images: wiring.images,
            limits: .standard,
            factory: TinyEMUGuestSessionFactory(),
            runtimeV2: wiring.runtimeV2
        )
        let service = TinyEMULinuxCommandService(registry: guestRegistry)
        // The runtime's own session table is the authoritative source for the
        // core count an already-running guest was granted; the run-shape claim
        // compares an explicit request against it instead of guessing.
        FloePlatformServices.shared.setLinuxRunningGuestVCPUProbe { environmentID in
            let states = await service.runtimeStates()
            guard let state = states.first(where: { $0.environmentID == environmentID }),
                  state.running else { return nil }
            return state.vcpus
        }
        // Hooks are published last, before the service can serve anyone.
        publishGuestWiring(wiring)
        return service
    }

    /// Complete wiring for an existing artifact root: resolver, Runtime v2
    /// substrate and the four global hook bundles. Construction publishes
    /// NOTHING (`prepareGuestWiring`); callers then install it atomically —
    /// launch assembly into a fresh registry (`publishGuestWiring`), or
    /// reconnect under the registry barrier (`reconnectBackend`). Launch and
    /// reconnect therefore can never diverge. No second installation service
    /// is created: callers pass the shared one.
    private struct PreparedGuestWiring {
        let images: any LinuxGuestImageResolving
        let runtimeV2: (any LinuxGuestRuntimeV2Integrating)?
        let runtimeV2Status: LinuxGuestRuntimeV2ImageStatus?
        let pinnedProbe: (@Sendable (String) async -> String?)?
        let officialTemplates: RuntimeV2OfficialTemplateService?
        let officialTemplateRuntime: LinuxOfficialTemplateRuntime?
    }

    private static func prepareGuestWiring(
        artifactRoot: URL,
        imageService: LinuxGuestImageInstallationService
    ) -> PreparedGuestWiring {
        let legacyRoot = artifactRoot
            .appendingPathComponent("LinuxGuest", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        let legacy = FileLinuxGuestImageResolver(root: legacyRoot)
        guard let layout = try? RuntimeV2Layout.production() else {
            // No v2 layout: the legacy resolver is the whole path; the pinned
            // probe is explicitly cleared, other hooks stay as launch left.
            return PreparedGuestWiring(
                images: legacy, runtimeV2: nil,
                runtimeV2Status: nil, pinnedProbe: nil,
                officialTemplates: nil, officialTemplateRuntime: nil
            )
        }
        // Startup-recovery stages feed the shared jobs object so the Linux
        // component card can present honest progress instead of an
        // indeterminate spinner while the first preparation salvages,
        // verifies and re-materializes gigabytes. Reporting never changes
        // recovery semantics.
        //
        // The sink is handed to the initializer rather than installed with
        // the actor-isolated `setPreparationStageHandler`: this wiring runs
        // in a synchronous (nonisolated) function, and constructor injection
        // both compiles there and registers the handler *before* the
        // integrator is reachable by any call — there is no post-init window
        // in which the first shared recovery pass could miss stages (no
        // unstructured Task registration race).
        let stageReport: @Sendable (RuntimeV2Store.RecoveryStage) -> Void = { stage in
            let raw = stage.rawValue
            Task { @MainActor in
                EnvironmentPackageJobs.shared.reportLinuxStorageStage(raw)
            }
        }
        let store = RuntimeV2Store(layout: layout)
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: legacyRoot,
            preparationStageHandler: stageReport
        )
        let images = RuntimeV2CompositeImageResolver(
            expandedImagesRoot: layout.expandedImagesDirectory,
            legacy: legacy,
            verifiedGate: { imageID in await integrator.isImageVerified(imageID: imageID) }
        )
        // Install-state truth for Settings and the IDE capability gate: after
        // the verified migration moves the legacy image directory aside, image
        // status must come from the v2 store — and it must answer from the
        // actual expanded bytes/blobs, never from the registry row alone.
        let runtimeV2Status = LinuxGuestRuntimeV2ImageStatus(
            isVerified: { imageID in
                await integrator.isImageVerifiedWithoutMigration(imageID: imageID)
            },
            expandedImagesRoot: layout.expandedImagesDirectory,
            // The verified manifest's own SMP declaration is the only image
            // evidence; the engine query is never consulted.
            smpCapability: { imageID in
                await integrator.imageSMPCapable(imageID: imageID)
            },
            health: { imageID, isCancelled in
                await integrator.imageHealth(imageID: imageID, isCancelled: isCancelled)
            },
            reverifyHealth: { imageID, isCancelled in
                await integrator.reverifyImageHealth(imageID: imageID, isCancelled: isCancelled)
            },
            reconstructExpanded: { imageID, isCancelled in
                try await integrator.reconstructExpandedImage(imageID: imageID, isCancelled: isCancelled)
            },
            repairFromLegacyInstall: { imageID, isCancelled in
                try await integrator.repairImageFromLegacyInstall(imageID: imageID, isCancelled: isCancelled)
            },
            // Environment-disk repair EXCLUSION truth (inspection only). The
            // RESOLUTION itself deliberately has no closure here: it must run
            // through the one serialized control service (registry lifecycle
            // ownership), exactly like the model-facing repair tool, never
            // through a raw store call that could bypass the exclusion.
            repairHoldStatus: { environmentID in
                await store.repairHoldStatus(environmentID: environmentID)
            },
            repairRecoverable: { environmentID in
                await store.verifyRecoverable(environmentID: environmentID)
            },
            preparationStage: {
                await integrator.preparationStage()
            }
        )
        // Pinned environments boot their immutable template's own image; the
        // environment provider and preparation both resolve it through this
        // probe.
        let pinnedProbe: @Sendable (String) async -> String? = { environmentID in
            await integrator.environmentTemplateBaseImageID(environmentID: environmentID)
        }
        // Official template distribution + registration through the existing
        // verified image store and template store.
        let officialTemplates = RuntimeV2OfficialTemplateService(
            store: store,
            importer: LinuxGuestImageTemplateAvailabilityAdapter(service: imageService),
            downloader: LinuxGuestImageHTTPDownloader()
        )
        let officialTemplateRuntime = LinuxOfficialTemplateRuntime(
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
        return PreparedGuestWiring(
            images: images, runtimeV2: integrator,
            runtimeV2Status: runtimeV2Status, pinnedProbe: pinnedProbe,
            officialTemplates: officialTemplates,
            officialTemplateRuntime: officialTemplateRuntime
        )
    }

    /// Publishes prepared hooks. Used by launch assembly after the fresh
    /// registry and command service are built but before they can serve
    /// anyone.
    private static func publishGuestWiring(_ wiring: PreparedGuestWiring) {
        let services = FloePlatformServices.shared
        services.setLinuxImageRuntimeV2(wiring.runtimeV2Status)
        services.setLinuxPinnedImageIDProbe(wiring.pinnedProbe)
        if let officialTemplates = wiring.officialTemplates {
            services.setLinuxOfficialTemplateService(officialTemplates)
        }
        if let officialTemplateRuntime = wiring.officialTemplateRuntime {
            services.setLinuxOfficialTemplateRuntime(officialTemplateRuntime)
        }
    }

    /// Recoverable reconnect after a transient assembly-time failure. The
    /// readiness sequence is strictly ordered:
    ///   1. construct every dependency and hook (nothing observable yet),
    ///   2. `begin`: the registry swaps the resolver ONLY when idle and then
    ///      refuses guest starts via its barrier — no start can interleave,
    ///   3. publish the matching global hooks while the barrier is held,
    ///   4. `commit`: admits starts again.
    /// A refused begin answers false with hooks and resolver unchanged.
    static func reconnectBackend(
        commandService: TinyEMULinuxCommandService,
        artifactRoot: URL,
        imageService: LinuxGuestImageInstallationService
    ) async -> Bool {
        let wiring = prepareGuestWiring(artifactRoot: artifactRoot, imageService: imageService)
        guard await commandService.beginLinuxBackendReconnect(
            images: wiring.images,
            runtimeV2: wiring.runtimeV2
        ) else { return false }
        publishGuestWiring(wiring)
        await commandService.commitLinuxBackendReconnect()
        return true
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
    ///
    /// `guestRunID` is the shell session's run identity. A guest-backed IDE
    /// script run has registered its accepted shape under exactly that run, so
    /// the start claims it (release-gated) while a terminal or another run
    /// keeps the worker default.
    private func activateWithPreparation(
        environmentID: String,
        taskID: String?,
        guestRunID: UUID?,
        cancellation: CancellationToken?
    ) async throws {
        do {
            try await FloePlatformServices.shared.activateLinuxGuest(
                id: environmentID, taskID: taskID, runID: guestRunID
            )
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error else { throw error }
            guard let prepareLinux else { throw error }
            let token = cancellation ?? CancellationToken()
            _ = try await prepareLinux(
                LinuxPreparationRequest(environmentID: environmentID, cancellation: token)
            )
            try await FloePlatformServices.shared.activateLinuxGuest(
                id: environmentID, taskID: taskID, runID: guestRunID
            )
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
                guestRunID: request.runID,
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
        // from scoped release anyway). The run identity is still passed so a
        // registered IDE run shape is claimed for exactly that run.
        try await activateWithPreparation(
            environmentID: environmentID,
            taskID: nil,
            guestRunID: request.runID,
            cancellation: cancellation
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
