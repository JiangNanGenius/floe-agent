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
import FloeTools

/// Maps Floe environment records onto Linux guest descriptors. Only
/// environments explicitly declared `executionBackend == .linuxVM` are owned
/// by the guest backend; deleted environments disappear immediately.
struct AppLinuxGuestEnvironmentProvider: LinuxGuestEnvironmentProviding {
    let registry: EnvironmentRegistry
    let defaultImageID: String

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

        return LinuxGuestEnvironmentDescriptor(
            id: record.id,
            ownerID: record.ownerID,
            taskID: nil,
            writableDirectory: layer,
            shares: Array(shares.prefix(LinuxGuestShare.maximumShares)),
            imageID: defaultImageID,
            ramMB: nil,
            // Linux environments need apt/pip to install python3 and packages.
            // Each admitted guest owns its network instance; the registry
            // controls concurrent VM admission and lifecycle.
            networkEnabled: true,
            serviceForwards: []
        )
    }
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
    static func makeService(registry: EnvironmentRegistry, artifactRoot: URL?) -> TinyEMULinuxCommandService {
        let images: any LinuxGuestImageResolving
        let runtimeV2: (any LinuxGuestRuntimeV2Integrating)?
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
                defaultImageID: defaultImageID
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
    private func activateWithPreparation(
        environmentID: String,
        cancellation: CancellationToken?
    ) async throws {
        do {
            try await FloePlatformServices.shared.activateLinuxGuest(id: environmentID)
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error else { throw error }
            guard let prepareLinux else { throw error }
            let token = cancellation ?? CancellationToken()
            _ = try await prepareLinux(
                LinuxPreparationRequest(environmentID: environmentID, cancellation: token)
            )
            try await FloePlatformServices.shared.activateLinuxGuest(id: environmentID)
        }
    }

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id,
              await guests.ownsLinuxEnvironment(environmentID: environmentID) else {
            return await native.run(request, cancellation: cancellation)
        }
        do {
            try await activateWithPreparation(environmentID: environmentID, cancellation: cancellation)
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
        try await activateWithPreparation(environmentID: environmentID, cancellation: cancellation)
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
